local classic = require 'classic'
local cudnn = require 'cudnn'
local cunn = require 'cunn'
local cutorch = require 'cutorch'
local torch = require 'torch'

local image_util = require 'util/image_util'

local Evaluator = classic.class('Evaluator')

function Evaluator:_init(args)
    --[[
    Used to evaluate the model on validation data. See trainer.lua for
    documentation of arguments.

    Args:
        model
        criterion
        data_loader
        input_dimension_permutation
        pixel_mean
        batch_size
        crop_size
        num_labels
    ]]--
    self.model = args.model
    self.criterion = args.criterion
    self.data_loader = args.data_loader
    -- Only use input permutation if it is not the identity.
    self.input_dimension_permutation = nil
    for i = 1, 5 do
        if args.input_dimension_permutation ~= nil
                and args.input_dimension_permutation[i] ~= i then
            self.input_dimension_permutation = args.input_dimension_permutation
            break
        end
    end
    self.pixel_mean = torch.Tensor(args.pixel_mean)
    self.batch_size = args.batch_size
    self.crop_size = args.crop_size
    self.num_labels = args.num_labels

    self.gpu_inputs = torch.CudaTensor()
    self.gpu_labels = torch.CudaTensor()

    -- Prefetch the next batch.
    self.data_loader:fetch_batch_async(self.batch_size)
end

function Evaluator:evaluate_batch()
    --[[
    Returns:
        loss: Output of criterion:forward on this batch.
        outputs (Tensor): Output of model:forward on this batch. The tensor
            size is (sequence_length, batch_size, num_labels)
        labels (Tensor): True labels. Same size as the outputs.
    ]]--
    local images_table, labels = self.data_loader:load_batch(self.batch_size)
    -- Prefetch the next batch.
    self.data_loader:fetch_batch_async(self.batch_size)

    local num_steps = #images_table
    local num_channels = images_table[1][1]:size(1)
    local images = torch.Tensor(num_steps, self.batch_size, num_channels,
                                self.crop_size, self.crop_size)
    for step, step_images in ipairs(images_table) do
        for sequence, img in ipairs(step_images) do
            -- Process image after converting to the default Tensor type.
            -- (Originally, it is a ByteTensor).
            images[{step, sequence}] = image_util.augment_image_eval(
                img, self.crop_size, self.crop_size, self.pixel_mean)
        end
    end
    if self.input_dimension_permutation then
        images = images:permute(unpack(self.input_dimension_permutation))
    end

    self.gpu_inputs:resize(images:size()):copy(images)
    self.gpu_labels:resize(labels:size()):copy(labels)
    local outputs = self.model:forward(self.gpu_inputs)
    -- If the output of the network is a single prediction for the sequence,
    -- compare it to the label of the last frame.
    if (outputs:size(1) == 1 or outputs:dim() == 2) and
            self.gpu_labels:size(1) ~= 1 then
        self.gpu_labels = self.gpu_labels[self.gpu_labels:size(1)]
    end
    local loss = self.criterion:forward(outputs, self.gpu_labels)

    return loss, outputs, labels
end

function Evaluator:evaluate_epoch(epoch, num_batches)
    cutorch.synchronize()
    self.model:evaluate()
    local epoch_timer = torch.Timer()
    local batch_timer = torch.Timer()

    local predictions = torch.Tensor(
        num_batches * self.batch_size, self.num_labels)
    local groundtruth = torch.ByteTensor(
        num_batches * self.batch_size, self.num_labels)

    local loss_epoch = 0
    for batch_index = 1, num_batches do
        batch_timer: reset()
        collectgarbage()
        local loss, curr_predictions, curr_groundtruth = self:evaluate_batch()
        loss_epoch = loss_epoch + loss

        -- We only care about the predictions and groundtruth in the last step
        -- of the sequence.
        if curr_predictions:dim() == 3 and curr_predictions:size(1) > 1 then
            curr_predictions = curr_predictions[curr_predictions:size(1)]
        end
        if curr_groundtruth:dim() == 3 and curr_groundtruth:size(1) > 1 then
            curr_groundtruth = curr_groundtruth[curr_groundtruth:size(1)]
        end

        -- Collect current predictions and groundtruth.
        local epoch_index_start = (batch_index - 1) * self.batch_size + 1
        predictions[{{epoch_index_start,
                      epoch_index_start + self.batch_size - 1},
                      {}}] = curr_predictions:type(predictions:type())
        groundtruth[{{epoch_index_start,
                      epoch_index_start + self.batch_size - 1},
                      {}}] = curr_groundtruth
    end

    local mean_average_precision = compute_mean_average_precision(
        predictions, groundtruth)
    print(string.format(
        '%s: Epoch: [%d][VALIDATION SUMMARY] Total Time(s): %.2f\t' ..
        'average loss (per batch): %.5f \t mAP: %.5f',
        os.date('%X'), epoch, epoch_timer:time().real, loss_epoch / num_batches,
        mean_average_precision))
    collectgarbage()
end

-- TODO(achald): Move this to a separate util file.
function compute_mean_average_precision(predictions, groundtruth)
    --[[
    Compute mean average prediction.

    Args:
        predictions ((num_samples, num_classes) Tensor)
        groundtruth ((num_samples, num_classes) Tensor): Contains 0/1 values.

    Returns:
        mean_average_precision (num)
    ]]--
    local num_labels = predictions:size(2)
    local average_precisions = torch.Tensor(num_labels):zero()
    local label_has_sample = torch.ByteTensor(num_labels):zero()
    --[[
    Let P(k) be the precision at cut-off for item k. Then, we compute average
    precision for each label as

    \frac{ \sum_{k=1}^n (P(k) * is_positive(k)) }{ # of relevant documents }

    where is_positive(k) is 1 if the groundtruth labeled item k as positive.
    ]]--
    for label = 1, num_labels do
        local label_groundtruth = groundtruth[{{}, label}]
        if torch.any(label_groundtruth) then
            label_has_sample[label] = 1
            local label_predictions = predictions[{{}, label}]
            local _, sorted_indices = torch.sort(
                label_predictions, 1, true --[[descending]])
            local true_positives = 0
            local average_precision = 0
            for num_guesses = 1, label_predictions:nElement() do
                local sample_index = sorted_indices[num_guesses]
                if label_groundtruth[sample_index] == 1 then
                    true_positives = true_positives + 1
                    local precision = true_positives / num_guesses
                    average_precision = average_precision + precision
                end
            end
            average_precisions[label] =
                average_precision / label_groundtruth:sum()
        end
    end
    -- Return mean of average precisions for labels which had at least 1 sample
    -- in the provided data.
    average_precisions = average_precisions[torch.eq(label_has_sample, 1)]
    if average_precisions:nElement() == 0 then
        print('No positive labels! Returning -1.')
        return -1
    end
    return torch.mean(average_precisions)
end

return {
    Evaluator = Evaluator,
    compute_mean_average_precision = compute_mean_average_precision
}
