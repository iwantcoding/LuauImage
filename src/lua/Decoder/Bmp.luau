--!strict

export type BmpImage = {
	width: number,
	height: number,
	pixels: buffer,
}

type BmpDecodeOptions = {
	verifyChecksums: boolean,
	onStage: ((string, number) -> ())?,
}

local BMP_MAX_PIXELS = 2 * 1024 * 1024
local BMP_MAX_ENCODED_BYTES = 20 * 1024 * 1024
local bmpBufferReadU8 = buffer.readu8
local bmpBufferReadU32 = buffer.readu32
local bmpBufferWriteU32 = buffer.writeu32
local bmpBufferFromString = buffer.fromstring
local bmpBitBand = bit32.band
local bmpBitRShift = bit32.rshift

local function readBmpU16LE(data: string, position: number): number
	local low = string.byte(data, position)
	local high = string.byte(data, position + 1)
	if high == nil then
		error("truncated BMP data", 0)
	end
	return low + high * 256
end

local function readBmpU32LE(data: string, position: number): number
	local first, second, third, fourth = string.byte(data, position, position + 3)
	if fourth == nil then
		error("truncated BMP data", 0)
	end
	return first + second * 256 + third * 65536 + fourth * 16777216
end

local function readBmpI32LE(data: string, position: number): number
	local value = readBmpU32LE(data, position)
	if value >= 2147483648 then
		return value - 4294967296
	end
	return value
end

local function decodeBmp(data: string): BmpImage
	if #data > BMP_MAX_ENCODED_BYTES then
		error("BMP exceeds the encoded image size limit", 0)
	end
	if #data < 54 or string.sub(data, 1, 2) ~= "BM" then
		error("data is not a supported BMP image", 0)
	end

	local fileSize = readBmpU32LE(data, 3)
	local pixelOffset = readBmpU32LE(data, 11)
	local dibHeaderSize = readBmpU32LE(data, 15)
	if dibHeaderSize < 40 or dibHeaderSize > #data - 14 then
		error("unsupported or truncated BMP DIB header", 0)
	end
	if fileSize ~= 0 and fileSize > #data then
		error("truncated BMP pixel data", 0)
	end

	local width = readBmpI32LE(data, 19)
	local signedHeight = readBmpI32LE(data, 23)
	local planes = readBmpU16LE(data, 27)
	local bitsPerPixel = readBmpU16LE(data, 29)
	local compression = readBmpU32LE(data, 31)
	if width <= 0 or signedHeight == 0 then
		error("invalid BMP dimensions", 0)
	end
	local height = math.abs(signedHeight)
	if width * height > BMP_MAX_PIXELS then
		error("BMP dimensions exceed the pixel limit", 0)
	end
	if planes ~= 1 then
		error("BMP must have exactly one color plane", 0)
	end
	if bitsPerPixel ~= 24 and bitsPerPixel ~= 32 then
		error("only 24-bit and 32-bit BMP images are supported", 0)
	end
	if compression ~= 0 then
		error("compressed or bitfield BMP images are not supported", 0)
	end
	if pixelOffset < 14 + dibHeaderSize then
		error("invalid BMP pixel-data offset", 0)
	end

	local bytesPerPixel = math.floor(bitsPerPixel / 8)
	local rowStride = math.floor((width * bitsPerPixel + 31) / 32) * 4
	local requiredPixelEnd = pixelOffset + rowStride * (height - 1) + width * bytesPerPixel
	if requiredPixelEnd > #data then
		error("truncated BMP pixel data", 0)
	end

	local source = bmpBufferFromString(data)
	local pixels = buffer.create(width * height * 4)
	for y = 0, height - 1 do
		local fileRow = if signedHeight > 0 then height - 1 - y else y
		local rowStart = pixelOffset + fileRow * rowStride
		for x = 0, width - 1 do
			local sourceOffset = rowStart + x * bytesPerPixel
			local outputOffset = (y * width + x) * 4
			if bitsPerPixel == 32 then
				local bgra = bmpBufferReadU32(source, sourceOffset)
				local blue = bmpBitBand(bgra, 0xFF)
				local green = bmpBitBand(bmpBitRShift(bgra, 8), 0xFF)
				local red = bmpBitBand(bmpBitRShift(bgra, 16), 0xFF)
				bmpBufferWriteU32(pixels, outputOffset, red + green * 256 + blue * 65536 + 255 * 16777216)
			else
				local blue = bmpBufferReadU8(source, sourceOffset)
				local green = bmpBufferReadU8(source, sourceOffset + 1)
				local red = bmpBufferReadU8(source, sourceOffset + 2)
				bmpBufferWriteU32(pixels, outputOffset, red + green * 256 + blue * 65536 + 255 * 16777216)
			end
		end
	end

	return {
		width = width,
		height = height,
		pixels = pixels,
	}
end

local BmpDecoder = {}

function BmpDecoder.isFormat(data: string): boolean
	return string.sub(data, 1, 2) == "BM"
end

function BmpDecoder.decode(data: string, _options: BmpDecodeOptions): BmpImage
	return decodeBmp(data)
end

return BmpDecoder
