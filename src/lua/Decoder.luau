--!strict

-- @include Decoder/Png
-- @include Decoder/Bmp

export type Image = {
	width: number,
	height: number,
	pixels: buffer,
}

export type DecodeResult =
	{ ok: true, image: Image }
	| { ok: false, error: string }

export type DecodeOptions = {
	verifyChecksums: boolean?,
	onStage: ((string, number) -> ())?,
}

type ResolvedDecodeOptions = {
	verifyChecksums: boolean,
	onStage: ((string, number) -> ())?,
}

type FormatDecoder = {
	isFormat: (data: string) -> boolean,
	decode: (data: string, options: ResolvedDecodeOptions) -> Image,
}

local formatDecoders: { FormatDecoder } = {
	PngDecoder,
	BmpDecoder,
}

local Decoder = {}

local function profileStage<T>(
	options: ResolvedDecodeOptions,
	name: string,
	callback: () -> T
): T
	debug.profilebegin(name)
	local startedAt = os.clock()
	local succeeded, result = pcall(callback)
	local elapsedMs = (os.clock() - startedAt) * 1000
	debug.profileend()
	if options.onStage ~= nil then
		options.onStage(name, elapsedMs)
	end
	if not succeeded then
		error(result, 0)
	end
	return result
end

function Decoder.decode(data: string, config: DecodeOptions?): DecodeResult
	if typeof(data) ~= "string" then
		return { ok = false, error = "image data must be a string" }
	end
	local options: ResolvedDecodeOptions = {
		verifyChecksums = if config == nil or config.verifyChecksums == nil then false else config.verifyChecksums,
		onStage = if config == nil then nil else config.onStage,
	}

	for _, formatDecoder in ipairs(formatDecoders) do
		if formatDecoder.isFormat(data) then
			local succeeded, image = pcall(function(): Image
				return profileStage(options, "Image decode", function(): Image
					return formatDecoder.decode(data, options)
				end)
			end)
			if not succeeded then
				return { ok = false, error = tostring(image) }
			end
			return { ok = true, image = image }
		end
	end

	return {
		ok = false,
		error = "unsupported image format. Only png and bmp",
	}
end

return Decoder
