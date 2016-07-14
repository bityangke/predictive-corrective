--[[ Computes activations for a given video.
--
-- Outputs a tensor which contains the output feature_map for each frame. The
-- first dimension is of size #frames.
--]]

local argparse = require 'argparse'
local classic = require 'classic'
local cunn = require 'cunn'
local cudnn = require 'cudnn'
local cutorch = require 'cutorch'
local image = require 'image'
local lmdb = require 'lmdb'
local torch = require 'torch'
local nn = require 'nn'
rnn = require 'rnn'

local data_loader = require 'data_loader'

local parser = argparse() {
    description = 'Computes activations for a given video for a VGG network.'
}
parser:option('--model', 'Torch model')
parser:option('--layer_type',
                'Layer type to output activations from. ' ..
                'E.g. cudnn.SpatialConvolution')
parser:option('--layer_type_index',
                'Which of the layer types to extract.'):convert(tonumber)
parser:option('--frames_lmdb')
parser:option('--video_name')
parser:option('--output_activations')

local args = parser:parse()

---
-- Configuration
---
local NETWORK_BATCH_SIZE = 64
-- Only supports one GPU. I can't figure out how to get activations from an
-- arbitrary layer on multiple GPUs easily.
local GPU = 1
local MEANS = {96.8293, 103.073, 101.662}
local CROP_SIZE = 224
local IMAGES_IN_BATCH = math.floor(NETWORK_BATCH_SIZE)
-- Unfortunately, this is necessary due to the way DataLoader is implemented.
local NUM_LABELS = 65
local SEQUENCE_LENGTH = 1
assert(SEQUENCE_LENGTH == 1) -- Only sequence length of 1 is supported.

math.randomseed(0)
torch.manualSeed(0)
cutorch.manualSeedAll(0)
cutorch.setDevice(GPU)
torch.setdefaulttensortype('torch.FloatTensor')

---
-- Load list of frame keys for video.
---
local VideoSampler = classic.class('VideoSampler', data_loader.Sampler)
function VideoSampler:_init(frames_lmdb, video_name, sequence_length)
    self.video_keys = data_loader.PermutedSampler.filter_end_frames(
        VideoSampler.get_video_keys(frames_lmdb, video_name),
        sequence_length)
    self.sequence_length = sequence_length
    self.key_index = 1
end

function VideoSampler:num_samples()
    return #self.video_keys
end

function VideoSampler:sample_keys(num_sequences)
    local batch_keys = {}
    for _ = 1, self.sequence_length do
        table.insert(batch_keys, {})
    end
    for _ = 1, num_sequences do
        if self.key_index > self:num_samples() then
            self.key_index = 1
        end
        local sampled_key = self.video_keys[self.key_index]
        for step = 1, self.sequence_length do
            table.insert(batch_keys[step], sampled_key)
            sampled_key = self.video_keys[self.key_index + step]
        end
        self.key_index = self.key_index + 1
    end
    return batch_keys
end

function VideoSampler.static.get_video_keys(frames_lmdb, video_name)
    local video_keys = {}
    local db = lmdb.env { Path = frames_lmdb }
    db:open()
    local transaction = db:txn(true --[[readonly]])
    local key = video_name .. '-1'
    while transaction:get(key) ~= nil do
        table.insert(video_keys, key)
        key = data_loader.Sampler.next_frame_key(key)
    end
    return video_keys
end

---
-- Load model.
---
print('Loading model.')
nn.DataParallelTable.deserializeNGPUs = 1
local model = torch.load(args.model)
if torch.isTypeOf(model, 'nn.DataParallelTable') then
    model = model:get(1)
end
if not torch.isTypeOf(model, 'nn.Sequencer') then
    model = nn.Sequencer(model)
end

model:evaluate()
print('Loaded model.')

---
-- Get requested layer.
---
print(args.layer_type)
print(args.layer_type_index)
print(#model:findModules(args.layer_type))

---
-- Pass frames through model
---
local sampler = VideoSampler(args.frames_lmdb, args.video_name, SEQUENCE_LENGTH)
local data_loader = data_loader.DataLoader(
    args.frames_lmdb, sampler, NUM_LABELS)

local gpu_inputs = torch.CudaTensor()
local samples_complete = 0
local layer_to_extract

local frame_activations = {}
while samples_complete ~= sampler:num_samples() do
    local to_load = IMAGES_IN_BATCH
    if samples_complete + IMAGES_IN_BATCH > sampler:num_samples() then
        to_load = sampler:num_samples() - samples_complete
    end
    local images_table, _, batch_keys = data_loader:load_batch(
        to_load, true --[[return_keys]])
    local batch_keys = batch_keys[SEQUENCE_LENGTH]

    local batch_size = #images_table[1]
    local num_channels = images_table[1][1]:size(1)
    local images = torch.Tensor(SEQUENCE_LENGTH, batch_size,
                                num_channels, CROP_SIZE, CROP_SIZE)
    for step, step_images in ipairs(images_table) do
        for batch_index, img in ipairs(step_images) do
            -- Process image after converting to the default Tensor type.
            -- (Originally, it is a ByteTensor).
            img = img:typeAs(images)
            for channel = 1, 3 do
                img[{{channel}, {}, {}}]:add(-MEANS[channel])
            end
            images[{step, batch_index}] = image.crop(
                img, 'c', CROP_SIZE, CROP_SIZE)
        end
    end

    layer_to_extract = model:findModules(args.layer_type)[args.layer_type_index]
    gpu_inputs:resize(images:size()):copy(images)
    model:forward(gpu_inputs)
    for i = 1, batch_size do
        frame_activations[batch_keys[i]] = layer_to_extract.output[i]:float()
    end
    samples_complete = samples_complete + to_load
    print(string.format('Computed activations for %d/%d.',
                        samples_complete, sampler:num_samples()))
end
print('Finished computing activations.')

---
-- Create activations tensor.
---
local activation_map_size = torch.totable(layer_to_extract.output[1]:size())
local activations_tensor = torch.zeros(sampler:num_samples(),
                                       unpack(activation_map_size))
for key, activation in pairs(frame_activations) do
    -- Keys are of the form '<filename>-<frame_number>'.
    -- Find the index of the '-'
    local _, split_index = string.find(key, '.*-')
    local frame_number = tonumber(string.sub(key, split_index + 1, -1))
    activations_tensor[frame_number] = activation
end
torch.save(args.output_activations, activations_tensor)