--[[
    MIT License

    See the LICENSE file in the root of this project
    for the full license text.
]]

-- This is auto merged, don't edit it manually

-- Module: Request

export type RequestOptions = {
	Url: string,
	Method: "GET" | "HEAD" | "POST" | "PUT" | "DELETE" | "OPTIONS" | "PATCH",
	Body: string?,
	Headers: { [string]: string }?,
	Cookies: { [string]: string }?,
}

export type RequestResponse = {
	Success: boolean,
	Body: string,
	StatusCode: number,
	StatusMessage: string,
	Headers: { [string]: string },
}

export type FetchResult =
	{ ok: true, body: string, statusCode: number }
	| { ok: false, error: string, statusCode: number? }

local Request = {}

function Request.fetch(url: string): FetchResult
	if not string.match(url, "^[Hh][Tt][Tt][Pp][Ss]?://") then
		return { ok = false, error = "URL must use HTTP or HTTPS" }
	end

	if typeof(request) ~= "function" then
		return { ok = false, error = "request function is unavailable" }
	end

	local callSucceeded, response = pcall(request, {
		Url = url,
		Method = "GET",
	})
	if not callSucceeded then
		return { ok = false, error = "request failed: " .. tostring(response) }
	end

	if typeof(response) ~= "table" then
		return { ok = false, error = "request returned an invalid response" }
	end

	local statusCode = response.StatusCode
	if typeof(response.Success) ~= "boolean" or typeof(statusCode) ~= "number" then
		return {
			ok = false,
			error = "request response is missing success or status information",
		}
	end

	if response.Success == false
		or (typeof(statusCode) == "number" and (statusCode < 200 or statusCode >= 300))
	then
		local statusMessage = response.StatusMessage
		local errorMessage = "request returned HTTP " .. tostring(statusCode)
		if typeof(statusMessage) == "string" and statusMessage ~= "" then
			errorMessage ..= " " .. statusMessage
		end

		return {
			ok = false,
			error = errorMessage,
			statusCode = statusCode,
		}
	end

	if typeof(response.Body) ~= "string" then
		return {
			ok = false,
			error = "request response is missing a string body",
			statusCode = statusCode,
		}
	end

	return {
		ok = true,
		body = response.Body,
		statusCode = statusCode,
	}
end

-- Module: Decoder/Png

export type PngImage = {
	width: number,
	height: number,
	pixels: buffer,
}

type BitReader = {
	data: buffer,
	position: number,
	endPosition: number,
	bitBuffer: number,
	bitCount: number,
}

type HuffmanTree = {
	maxBits: number,
	counts: { number },
	firstCodes: { number },
	offsets: { number },
	symbols: { number },
	fast: { number },
}

type ParsedPng = {
	width: number,
	height: number,
	colorType: number,
	compressedData: string,
	palette: string?,
	transparency: string?,
}

type PngDecodeOptions = {
	verifyChecksums: boolean,
	onStage: ((string, number) -> ())?,
}

type PngDecodeConfig = {
	verifyChecksums: boolean?,
	onStage: ((string, number) -> ())?,
}

local MAX_ENCODED_BYTES = 20 * 1024 * 1024
local MAX_PIXELS = 1024 * 1024
local ADLER_MODULUS = 65521
local PNG_SIGNATURE = "\137PNG\r\n\026\n"
local CRC_POLYNOMIAL = 0xEDB88320
local FAST_HUFFMAN_BITS = 9
local FAST_HUFFMAN_SIZE = 512
local bufferReadU8 = buffer.readu8
local bufferReadU32 = buffer.readu32
local bufferWriteU8 = buffer.writeu8
local bufferWriteU32 = buffer.writeu32
local bufferCopy = buffer.copy
local bufferFill = buffer.fill
local bufferFromString = buffer.fromstring
local bitBand = bit32.band
local bitBOr = bit32.bor
local bitLShift = bit32.lshift
local bitRShift = bit32.rshift

local LENGTH_BASE = {
	3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27,
	31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
}
local LENGTH_EXTRA = {
	0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
	2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
}
local DISTANCE_BASE = {
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
	193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
	6145, 8193, 12289, 16385, 24577,
}
local DISTANCE_EXTRA = {
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
	6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}
local CODE_LENGTH_ORDER = {
	16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
}

local function addPackedBytesU32(left: number, right: number): number
	local laneMask = 0x00FF00FF
	local lowBytes = bitBand(left, laneMask) + bitBand(right, laneMask)
	local highBytes = bitBand(bitRShift(left, 8), laneMask)
		+ bitBand(bitRShift(right, 8), laneMask)
	return bitBOr(bitBand(lowBytes, laneMask), bitLShift(bitBand(highBytes, laneMask), 8))
end

local function profilePngStage<T>(
	options: PngDecodeOptions,
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

local function readU32BE(data: string, position: number): number
	local first, second, third, fourth = string.byte(data, position, position + 3)
	if fourth == nil then
		error("truncated PNG data", 0)
	end
	return first * 16777216 + second * 65536 + third * 256 + fourth
end

local CRC_TABLE = table.create(256, 0)
for index = 0, 255 do
	local value = index
	for _ = 1, 8 do
		if bit32.band(value, 1) == 1 then
			value = bit32.bxor(bit32.rshift(value, 1), CRC_POLYNOMIAL)
		else
			value = bit32.rshift(value, 1)
		end
	end
	CRC_TABLE[index + 1] = value
end

local function updateCrc(
	crc: number,
	data: string,
	first: number,
	last: number
): number
	for index = first, last do
		local byte = string.byte(data, index)
		if byte == nil then
			error("truncated PNG chunk", 0)
		end
		crc = bit32.bxor(bit32.rshift(crc, 8), CRC_TABLE[bit32.band(bit32.bxor(crc, byte), 0xFF) + 1])
	end
	return crc
end

local function parsePng(data: string, options: PngDecodeOptions): ParsedPng
	if #data > MAX_ENCODED_BYTES then
		error("PNG exceeds the encoded image size limit", 0)
	end
	if string.sub(data, 1, #PNG_SIGNATURE) ~= PNG_SIGNATURE then
		error("data is not a PNG image", 0)
	end

	local width: number? = nil
	local height: number? = nil
	local colorType: number? = nil
	local palette: string? = nil
	local transparency: string? = nil
	local idatParts = {}
	local sawHeader = false
	local sawPalette = false
	local sawTransparency = false
	local sawImageData = false
	local imageDataEnded = false
	local sawEnd = false
	local offset = #PNG_SIGNATURE + 1

	while offset <= #data do
		if offset + 7 > #data then
			error("truncated PNG chunk header", 0)
		end

		local chunkLength = readU32BE(data, offset)
		local chunkType = string.sub(data, offset + 4, offset + 7)
		local chunkDataStart = offset + 8
		local chunkDataEnd = chunkDataStart + chunkLength - 1
		local crcPosition = chunkDataStart + chunkLength
		if crcPosition + 3 > #data then
			error("truncated PNG chunk data", 0)
		end

		if options.verifyChecksums then
			local crc = updateCrc(0xFFFFFFFF, data, offset + 4, offset + 7)
			if chunkLength > 0 then
				crc = updateCrc(crc, data, chunkDataStart, chunkDataEnd)
			end
			crc = bit32.bxor(crc, 0xFFFFFFFF)
			if crc ~= readU32BE(data, crcPosition) then
				error("PNG chunk checksum mismatch", 0)
			end
		end

		local chunkData = string.sub(data, chunkDataStart, chunkDataEnd)
		if not sawHeader then
			if chunkType ~= "IHDR" or chunkLength ~= 13 then
				error("PNG must begin with a 13-byte IHDR chunk", 0)
			end
			width = readU32BE(chunkData, 1)
			height = readU32BE(chunkData, 5)
			local bitDepth = string.byte(chunkData, 9)
			colorType = string.byte(chunkData, 10)
			local compressionMethod = string.byte(chunkData, 11)
			local filterMethod = string.byte(chunkData, 12)
			local interlaceMethod = string.byte(chunkData, 13)

			if width == nil or height == nil or width == 0 or height == 0 or width * height > MAX_PIXELS then
				error("PNG dimensions are empty or exceed the pixel limit", 0)
			end
			if bitDepth ~= 8 then
				error("only 8-bit PNG images are supported", 0)
			end
			if colorType ~= 0 and colorType ~= 2 and colorType ~= 3 and colorType ~= 4 and colorType ~= 6 then
				error("unsupported PNG color type", 0)
			end
			if compressionMethod ~= 0 or filterMethod ~= 0 then
				error("unsupported PNG compression or filter method", 0)
			end
			if interlaceMethod ~= 0 then
				error("interlaced PNG images are not supported", 0)
			end
			sawHeader = true
		elseif chunkType == "IHDR" then
			error("PNG contains multiple IHDR chunks", 0)
		elseif chunkType == "PLTE" then
			if sawPalette or sawImageData or chunkLength == 0 or chunkLength > 768 or chunkLength % 3 ~= 0 then
				error("invalid PNG palette", 0)
			end
			if colorType == 0 or colorType == 4 then
				error("grayscale PNG images cannot contain a palette", 0)
			end
			palette = chunkData
			sawPalette = true
		elseif chunkType == "tRNS" then
			if sawTransparency or sawImageData then
				error("invalid PNG transparency chunk order", 0)
			end
			transparency = chunkData
			sawTransparency = true
		elseif chunkType == "IDAT" then
			if imageDataEnded then
				error("PNG IDAT chunks must be consecutive", 0)
			end
			sawImageData = true
			table.insert(idatParts, chunkData)
		elseif chunkType == "IEND" then
			if chunkLength ~= 0 or not sawImageData then
				error("invalid PNG end chunk", 0)
			end
			sawEnd = true
			offset = crcPosition + 4
			break
		else
			if sawImageData then
				imageDataEnded = true
			end
			local firstByte = string.byte(chunkType, 1)
			if firstByte ~= nil and firstByte >= 65 and firstByte <= 90 then
				error("unsupported critical PNG chunk " .. chunkType, 0)
			end
		end

		if sawImageData and chunkType ~= "IDAT" then
			imageDataEnded = true
		end
		offset = crcPosition + 4
	end

	if not sawEnd or offset ~= #data + 1 then
		error("PNG is missing IEND or contains trailing data", 0)
	end
	if colorType == 3 and not sawPalette then
		error("indexed PNG image is missing its palette", 0)
	end
	if transparency ~= nil then
		if colorType == 0 and #transparency ~= 2 then
			error("invalid grayscale PNG transparency data", 0)
		elseif colorType == 2 and #transparency ~= 6 then
			error("invalid truecolor PNG transparency data", 0)
		elseif colorType == 3 and (palette == nil or #transparency > #palette / 3) then
			error("invalid indexed PNG transparency data", 0)
		elseif colorType ~= 0 and colorType ~= 2 and colorType ~= 3 then
			error("PNG transparency chunks are not valid for this color type", 0)
		end
	end

	return {
		width = width :: number,
		height = height :: number,
		colorType = colorType :: number,
		compressedData = table.concat(idatParts),
		palette = palette,
		transparency = transparency,
	}
end

local function ensureBits(reader: BitReader, count: number)
	while reader.bitCount < count and reader.position < reader.endPosition do
		local byte = bufferReadU8(reader.data, reader.position)
		reader.bitBuffer = bitBOr(reader.bitBuffer, bitLShift(byte, reader.bitCount))
		reader.bitCount += 8
		reader.position += 1
	end
end

local function readBits(reader: BitReader, count: number): number
	ensureBits(reader, count)
	if reader.bitCount < count then
		error("truncated DEFLATE stream", 0)
	end

	local mask = bitLShift(1, count) - 1
	local value = bitBand(reader.bitBuffer, mask)
	reader.bitBuffer = bitRShift(reader.bitBuffer, count)
	reader.bitCount -= count
	return value
end

local function alignReader(reader: BitReader)
	local paddingBits = reader.bitCount % 8
	reader.bitBuffer = bitRShift(reader.bitBuffer, paddingBits)
	reader.bitCount -= paddingBits
end

local function reverseBits(value: number, count: number): number
	local reversed = 0
	for _ = 1, count do
		reversed = reversed * 2 + bitBand(value, 1)
		value = bitRShift(value, 1)
	end
	return reversed
end

local function buildHuffman(lengths: { number }): HuffmanTree
	local counts = table.create(16, 0)
	local maxBits = 0
	for _, length in ipairs(lengths) do
		if length < 0 or length > 15 then
			error("invalid DEFLATE Huffman code length", 0)
		end
		if length > 0 then
			counts[length + 1] += 1
			maxBits = math.max(maxBits, length)
		end
	end

	local symbols = table.create(#lengths, 0)
	local fast = table.create(FAST_HUFFMAN_SIZE, 0)
	if maxBits == 0 then
		return {
			maxBits = 0,
			counts = counts,
			firstCodes = table.create(16, 0),
			offsets = table.create(16, 0),
			symbols = symbols,
			fast = fast,
		}
	end

	local remainingCodes = 1
	for bits = 1, maxBits do
		remainingCodes = remainingCodes * 2 - counts[bits + 1]
		if remainingCodes < 0 then
			error("oversubscribed DEFLATE Huffman tree", 0)
		end
	end

	local nextCode = table.create(16, 0)
	local code = 0
	for bits = 1, maxBits do
		code = (code + counts[bits]) * 2
		nextCode[bits + 1] = code
	end
	local firstCodes = table.clone(nextCode)

	local offsets = table.create(16, 0)
	for bits = 1, maxBits do
		offsets[bits + 1] = offsets[bits] + counts[bits]
	end
	local cursors = table.create(16, 0)
	for bits = 1, maxBits do
		cursors[bits + 1] = offsets[bits + 1]
	end

	for symbolIndex, length in ipairs(lengths) do
		if length > 0 then
			local canonicalCode = nextCode[length + 1]
			nextCode[length + 1] = canonicalCode + 1

			local slot = cursors[length + 1] + 1
			symbols[slot] = symbolIndex - 1
			cursors[length + 1] += 1

			if length <= FAST_HUFFMAN_BITS then
				local reversedCode = reverseBits(canonicalCode, length)
				local increment = 2 ^ length
				local packedSymbol = (symbolIndex - 1) * 16 + length
				for fastIndex = reversedCode, FAST_HUFFMAN_SIZE - 1, increment do
					fast[fastIndex + 1] = packedSymbol
				end
			end
		end
	end

	return {
		maxBits = maxBits,
		counts = counts,
		firstCodes = firstCodes,
		offsets = offsets,
		symbols = symbols,
		fast = fast,
	}
end

local function decodeSymbol(reader: BitReader, tree: HuffmanTree): number
	if tree.maxBits == 0 then
		error("invalid DEFLATE Huffman code", 0)
	end

	ensureBits(reader, FAST_HUFFMAN_BITS)
	if reader.bitCount >= FAST_HUFFMAN_BITS then
		local fastIndex = bitBand(reader.bitBuffer, FAST_HUFFMAN_SIZE - 1) + 1
		local packedSymbol = tree.fast[fastIndex]
		if packedSymbol ~= 0 then
			local codeLength = bitBand(packedSymbol, 0xF)
			local symbol = bitRShift(packedSymbol, 4)
			reader.bitBuffer = bitRShift(reader.bitBuffer, codeLength)
			reader.bitCount -= codeLength
			return symbol
		end
	end

	local code = 0
	for length = 1, tree.maxBits do
		code = code * 2 + readBits(reader, 1)
		local codeCount = tree.counts[length + 1]
		local firstCode = tree.firstCodes[length + 1]
		local symbolIndex = code - firstCode
		if symbolIndex >= 0 and symbolIndex < codeCount then
			return tree.symbols[tree.offsets[length + 1] + symbolIndex + 1]
		end
	end
	error("invalid DEFLATE Huffman code", 0)
end

local function makeFixedTrees(): (HuffmanTree, HuffmanTree)
	local literalLengths = table.create(288, 0)
	for symbol = 0, 143 do
		literalLengths[symbol + 1] = 8
	end
	for symbol = 144, 255 do
		literalLengths[symbol + 1] = 9
	end
	for symbol = 256, 279 do
		literalLengths[symbol + 1] = 7
	end
	for symbol = 280, 287 do
		literalLengths[symbol + 1] = 8
	end

	local distanceLengths = table.create(32, 5)
	return buildHuffman(literalLengths), buildHuffman(distanceLengths)
end

local FIXED_LITERAL_TREE, FIXED_DISTANCE_TREE = makeFixedTrees()

local function makeDynamicTrees(reader: BitReader): (HuffmanTree, HuffmanTree)
	local literalCount = readBits(reader, 5) + 257
	local distanceCount = readBits(reader, 5) + 1
	local codeLengthCount = readBits(reader, 4) + 4
	if literalCount > 286 then
		error("invalid DEFLATE literal/length code count", 0)
	end
	local codeLengthLengths = table.create(19, 0)

	for index = 1, codeLengthCount do
		local symbol = CODE_LENGTH_ORDER[index]
		codeLengthLengths[symbol + 1] = readBits(reader, 3)
	end

	local codeLengthTree = buildHuffman(codeLengthLengths)
	local totalCount = literalCount + distanceCount
	local combinedLengths = table.create(totalCount, 0)
	local currentIndex = 1

	while currentIndex <= totalCount do
		local symbol = decodeSymbol(reader, codeLengthTree)
		if symbol <= 15 then
			combinedLengths[currentIndex] = symbol
			currentIndex += 1
		elseif symbol == 16 then
			if currentIndex == 1 then
				error("invalid DEFLATE repeat code", 0)
			end
			local repeatCount = readBits(reader, 2) + 3
			if currentIndex + repeatCount - 1 > totalCount then
				error("DEFLATE code-length repeat exceeds its table", 0)
			end
			local previousLength = combinedLengths[currentIndex - 1]
			for _ = 1, repeatCount do
				combinedLengths[currentIndex] = previousLength
				currentIndex += 1
			end
		elseif symbol == 17 then
			local repeatCount = readBits(reader, 3) + 3
			if currentIndex + repeatCount - 1 > totalCount then
				error("DEFLATE code-length repeat exceeds its table", 0)
			end
			for _ = 1, repeatCount do
				combinedLengths[currentIndex] = 0
				currentIndex += 1
			end
		elseif symbol == 18 then
			local repeatCount = readBits(reader, 7) + 11
			if currentIndex + repeatCount - 1 > totalCount then
				error("DEFLATE code-length repeat exceeds its table", 0)
			end
			for _ = 1, repeatCount do
				combinedLengths[currentIndex] = 0
				currentIndex += 1
			end
		else
			error("invalid DEFLATE code-length symbol", 0)
		end
	end

	local literalLengths = table.create(literalCount, 0)
	local distanceLengths = table.create(distanceCount, 0)
	for index = 1, literalCount do
		literalLengths[index] = combinedLengths[index]
	end
	for index = 1, distanceCount do
		distanceLengths[index] = combinedLengths[literalCount + index]
	end
	if literalLengths[257] == 0 then
		error("DEFLATE literal tree has no end-of-block code", 0)
	end

	return buildHuffman(literalLengths), buildHuffman(distanceLengths)
end

local function inflateZlib(
	data: string,
	expectedSize: number,
	options: PngDecodeOptions
): buffer
	if #data < 6 then
		error("truncated zlib data", 0)
	end

	local compressionMethod = string.byte(data, 1)
	local flags = string.byte(data, 2)
	if compressionMethod % 16 ~= 8 or math.floor(compressionMethod / 16) > 7 then
		error("unsupported zlib compression method or window size", 0)
	end
	if (compressionMethod * 256 + flags) % 31 ~= 0 then
		error("invalid zlib header checksum", 0)
	end
	if bit32.band(flags, 0x20) ~= 0 then
		error("preset zlib dictionaries are not supported", 0)
	end

	local input = bufferFromString(data)
	local reader: BitReader = {
		data = input,
		position = 2,
		endPosition = #data - 4,
		bitBuffer = 0,
		bitCount = 0,
	}
	local output = buffer.create(expectedSize)
	local outputOffset = 0

	local isFinalBlock = false
	repeat
		isFinalBlock = readBits(reader, 1) == 1
		local blockType = readBits(reader, 2)
		if blockType == 0 then
			alignReader(reader)
			local length = readBits(reader, 16)
			local inverseLength = readBits(reader, 16)
			if bitBand(length + inverseLength, 0xFFFF) ~= 0xFFFF then
				error("invalid uncompressed DEFLATE block length", 0)
			end
			if outputOffset + length > expectedSize then
				error("DEFLATE data exceeds the expected image size", 0)
			end
			local bufferedBytes = reader.bitCount / 8
			local copiedBuffered = math.min(length, bufferedBytes)
			for _ = 1, copiedBuffered do
				bufferWriteU8(output, outputOffset, bitBand(reader.bitBuffer, 0xFF))
				reader.bitBuffer = bitRShift(reader.bitBuffer, 8)
				reader.bitCount -= 8
				outputOffset += 1
			end
			local remainingLength = length - copiedBuffered
			if reader.position + remainingLength > reader.endPosition then
				error("truncated DEFLATE stream", 0)
			end
			if remainingLength > 0 then
				bufferCopy(output, outputOffset, input, reader.position, remainingLength)
				reader.position += remainingLength
				outputOffset += remainingLength
			end
		elseif blockType == 1 or blockType == 2 then
			local literalTree: HuffmanTree
			local distanceTree: HuffmanTree
			if blockType == 1 then
				literalTree, distanceTree = FIXED_LITERAL_TREE, FIXED_DISTANCE_TREE
			else
				literalTree, distanceTree = makeDynamicTrees(reader)
			end

			while true do
				local symbol = decodeSymbol(reader, literalTree)
				if symbol < 256 then
					if outputOffset >= expectedSize then
						error("DEFLATE data exceeds the expected image size", 0)
					end
					bufferWriteU8(output, outputOffset, symbol)
					outputOffset += 1
				elseif symbol == 256 then
					break
				elseif symbol <= 285 then
					local lengthIndex = symbol - 256
					local length = LENGTH_BASE[lengthIndex] + readBits(reader, LENGTH_EXTRA[lengthIndex])
					if outputOffset + length > expectedSize then
						error("DEFLATE data exceeds the expected image size", 0)
					end
					local distanceSymbol = decodeSymbol(reader, distanceTree)
					if distanceSymbol > 29 then
						error("invalid DEFLATE distance symbol", 0)
					end
					local distance = DISTANCE_BASE[distanceSymbol + 1]
						+ readBits(reader, DISTANCE_EXTRA[distanceSymbol + 1])
					if distance > outputOffset then
						error("DEFLATE distance exceeds available output", 0)
					end
					if distance == 1 then
						bufferFill(output, outputOffset, bufferReadU8(output, outputOffset - 1), length)
						outputOffset += length
					elseif distance >= length then
						bufferCopy(output, outputOffset, output, outputOffset - distance, length)
						outputOffset += length
					else
						for _ = 1, length do
							local sourceOffset = outputOffset - distance
							bufferWriteU8(output, outputOffset, bufferReadU8(output, sourceOffset))
							outputOffset += 1
						end
					end
				else
					error("reserved DEFLATE literal/length symbol", 0)
				end
			end
		else
			error("reserved DEFLATE block type", 0)
		end
	until isFinalBlock

	if outputOffset ~= expectedSize then
		error("DEFLATE output size does not match PNG dimensions", 0)
	end

	alignReader(reader)
	if reader.bitCount ~= 0 or reader.position ~= reader.endPosition then
		error("invalid zlib trailer length", 0)
	end
	if options.verifyChecksums then
		local expectedAdler = bufferReadU8(input, reader.endPosition) * 16777216
			+ bufferReadU8(input, reader.endPosition + 1) * 65536
			+ bufferReadU8(input, reader.endPosition + 2) * 256
			+ bufferReadU8(input, reader.endPosition + 3)
		local a = 1
		local b = 0
		local nextAdlerUpdate = 5552
		for index = 0, expectedSize - 1 do
			a += bufferReadU8(output, index)
			b += a
			if index + 1 >= nextAdlerUpdate then
				a %= ADLER_MODULUS
				b %= ADLER_MODULUS
				nextAdlerUpdate += 5552
			end
		end
		a %= ADLER_MODULUS
		b %= ADLER_MODULUS
		local actualAdler = b * 65536 + a
		if actualAdler ~= expectedAdler then
			error("zlib Adler-32 checksum mismatch", 0)
		end
	end

	return output
end

local function unfilterPng(
	inflated: buffer,
	height: number,
	rowBytes: number,
	bytesPerPixel: number
)
	for row = 0, height - 1 do
		local inputRowOffset = row * (rowBytes + 1)
		local outputRowOffset = row * rowBytes
		local filterType = bufferReadU8(inflated, inputRowOffset)
		if filterType > 4 then
			error("unsupported PNG row filter", 0)
		end

		if filterType == 0 then
			if bytesPerPixel == 4 then
				for column = 0, rowBytes - 1, 4 do
					local destinationOffset = outputRowOffset + column
					bufferWriteU32(
						inflated,
						destinationOffset,
						bufferReadU32(inflated, inputRowOffset + column + 1)
					)
				end
			else
				for column = 0, rowBytes - 1 do
					local destinationOffset = outputRowOffset + column
					bufferWriteU8(
						inflated,
						destinationOffset,
						bufferReadU8(inflated, inputRowOffset + column + 1)
					)
				end
			end
		elseif filterType == 1 then
			if bytesPerPixel == 4 then
				for column = 0, rowBytes - 1, 4 do
					local destinationOffset = outputRowOffset + column
					local raw = bufferReadU32(inflated, inputRowOffset + column + 1)
					if column >= 4 then
						raw = addPackedBytesU32(raw, bufferReadU32(inflated, destinationOffset - 4))
					end
					bufferWriteU32(inflated, destinationOffset, raw)
				end
			else
				for column = 0, rowBytes - 1 do
					local destinationOffset = outputRowOffset + column
					local raw = bufferReadU8(inflated, inputRowOffset + column + 1)
					local left = if column >= bytesPerPixel
						then bufferReadU8(inflated, destinationOffset - bytesPerPixel)
						else 0
					bufferWriteU8(inflated, destinationOffset, (raw + left) % 256)
				end
			end
		elseif filterType == 2 then
			if bytesPerPixel == 4 then
				for column = 0, rowBytes - 1, 4 do
					local destinationOffset = outputRowOffset + column
					local raw = bufferReadU32(inflated, inputRowOffset + column + 1)
					local above = if row > 0 then bufferReadU32(inflated, destinationOffset - rowBytes) else 0
					bufferWriteU32(inflated, destinationOffset, addPackedBytesU32(raw, above))
				end
			else
				for column = 0, rowBytes - 1 do
					local destinationOffset = outputRowOffset + column
					local raw = bufferReadU8(inflated, inputRowOffset + column + 1)
					local above = if row > 0 then bufferReadU8(inflated, destinationOffset - rowBytes) else 0
					bufferWriteU8(inflated, destinationOffset, (raw + above) % 256)
				end
			end
		elseif filterType == 3 then
			if bytesPerPixel == 4 then
				for column = 0, rowBytes - 1, 4 do
					local destinationOffset = outputRowOffset + column
					local raw = bufferReadU32(inflated, inputRowOffset + column + 1)
					local left = if column >= 4 then bufferReadU32(inflated, destinationOffset - 4) else 0
					local above = if row > 0 then bufferReadU32(inflated, destinationOffset - rowBytes) else 0
					local value = 0
					for channel = 0, 3 do
						local shift = channel * 8
						local rawByte = bitBand(bitRShift(raw, shift), 0xFF)
						local leftByte = bitBand(bitRShift(left, shift), 0xFF)
						local aboveByte = bitBand(bitRShift(above, shift), 0xFF)
						local filteredByte = (rawByte + math.floor((leftByte + aboveByte) / 2)) % 256
						value = bitBOr(value, bitLShift(filteredByte, shift))
					end
					bufferWriteU32(inflated, destinationOffset, value)
				end
			else
				for column = 0, rowBytes - 1 do
					local destinationOffset = outputRowOffset + column
					local raw = bufferReadU8(inflated, inputRowOffset + column + 1)
					local left = if column >= bytesPerPixel
						then bufferReadU8(inflated, destinationOffset - bytesPerPixel)
						else 0
					local above = if row > 0 then bufferReadU8(inflated, destinationOffset - rowBytes) else 0
					bufferWriteU8(inflated, destinationOffset, (raw + math.floor((left + above) / 2)) % 256)
				end
			end
		elseif filterType == 4 and bytesPerPixel == 4 then
			for column = 0, rowBytes - 1, 4 do
				local destinationOffset = outputRowOffset + column
				local raw = bufferReadU32(inflated, inputRowOffset + column + 1)
				local left = if column >= 4 then bufferReadU32(inflated, destinationOffset - 4) else 0
				local above = if row > 0 then bufferReadU32(inflated, destinationOffset - rowBytes) else 0
				local upperLeft = if row > 0 and column >= 4
					then bufferReadU32(inflated, destinationOffset - rowBytes - 4)
					else 0
				local value = 0
				for channel = 0, 3 do
					local shift = channel * 8
					local rawByte = bitBand(bitRShift(raw, shift), 0xFF)
					local leftByte = bitBand(bitRShift(left, shift), 0xFF)
					local aboveByte = bitBand(bitRShift(above, shift), 0xFF)
					local upperLeftByte = bitBand(bitRShift(upperLeft, shift), 0xFF)
					local estimate = leftByte + aboveByte - upperLeftByte
					local leftDistance = math.abs(estimate - leftByte)
					local aboveDistance = math.abs(estimate - aboveByte)
					local upperLeftDistance = math.abs(estimate - upperLeftByte)
					local predictor = if leftDistance <= aboveDistance and leftDistance <= upperLeftDistance
						then leftByte
						elseif aboveDistance <= upperLeftDistance then aboveByte
						else upperLeftByte
					value = bitBOr(value, bitLShift((rawByte + predictor) % 256, shift))
				end
				bufferWriteU32(inflated, destinationOffset, value)
			end
		else
			for column = 0, rowBytes - 1 do
				local destinationOffset = outputRowOffset + column
				local raw = bufferReadU8(inflated, inputRowOffset + column + 1)
				local left = if column >= bytesPerPixel
					then bufferReadU8(inflated, destinationOffset - bytesPerPixel)
					else 0
				local above = if row > 0 then bufferReadU8(inflated, destinationOffset - rowBytes) else 0
				local upperLeft = if row > 0 and column >= bytesPerPixel
					then bufferReadU8(inflated, destinationOffset - rowBytes - bytesPerPixel)
					else 0
				local estimate = left + above - upperLeft
				local leftDistance = math.abs(estimate - left)
				local aboveDistance = math.abs(estimate - above)
				local upperLeftDistance = math.abs(estimate - upperLeft)
				local predictor = if leftDistance <= aboveDistance and leftDistance <= upperLeftDistance
					then left
					elseif aboveDistance <= upperLeftDistance then above
					else upperLeft
				local value = (raw + predictor) % 256
				bufferWriteU8(inflated, destinationOffset, value)
			end
		end
	end
end

local function writeRgba(
	output: buffer,
	pixelIndex: number,
	red: number,
	green: number,
	blue: number,
	alpha: number
)
	local offset = pixelIndex * 4
	bufferWriteU32(output, offset, red + green * 256 + blue * 65536 + alpha * 16777216)
end

local function convertToRgba(parsed: ParsedPng, scanlines: buffer): buffer
	local pixelCount = parsed.width * parsed.height
	local output = buffer.create(pixelCount * 4)
	if parsed.colorType == 6 then
		bufferCopy(output, 0, scanlines, 0, pixelCount * 4)
		return output
	end

	if parsed.colorType == 0 then
		local transparentGray: number? = nil
		if parsed.transparency ~= nil then
			transparentGray = string.byte(parsed.transparency, 1) * 256
				+ string.byte(parsed.transparency, 2)
		end
		for pixelIndex = 0, pixelCount - 1 do
			local gray = bufferReadU8(scanlines, pixelIndex)
			local alpha = if transparentGray == gray then 0 else 255
			writeRgba(output, pixelIndex, gray, gray, gray, alpha)
		end
	elseif parsed.colorType == 2 then
		local transparentRed: number? = nil
		local transparentGreen: number? = nil
		local transparentBlue: number? = nil
		if parsed.transparency ~= nil then
			transparentRed = string.byte(parsed.transparency, 1) * 256
				+ string.byte(parsed.transparency, 2)
			transparentGreen = string.byte(parsed.transparency, 3) * 256
				+ string.byte(parsed.transparency, 4)
			transparentBlue = string.byte(parsed.transparency, 5) * 256
				+ string.byte(parsed.transparency, 6)
		end
		for pixelIndex = 0, pixelCount - 1 do
			local sourceOffset = pixelIndex * 3
			local red = bufferReadU8(scanlines, sourceOffset)
			local green = bufferReadU8(scanlines, sourceOffset + 1)
			local blue = bufferReadU8(scanlines, sourceOffset + 2)
			local alpha = if red == transparentRed and green == transparentGreen and blue == transparentBlue
				then 0
				else 255
			writeRgba(output, pixelIndex, red, green, blue, alpha)
		end
	elseif parsed.colorType == 3 then
		local palette = parsed.palette
		if palette == nil then
			error("indexed PNG image is missing its palette", 0)
		end
		local paletteCount = #palette / 3
		local packedPalette = table.create(paletteCount, 0)
		for paletteIndex = 0, paletteCount - 1 do
			local paletteOffset = paletteIndex * 3 + 1
			local red = string.byte(palette, paletteOffset)
			local green = string.byte(palette, paletteOffset + 1)
			local blue = string.byte(palette, paletteOffset + 2)
			local alpha = if parsed.transparency ~= nil and paletteIndex < #parsed.transparency
				then string.byte(parsed.transparency, paletteIndex + 1)
				else 255
			packedPalette[paletteIndex + 1] = red + green * 256 + blue * 65536 + alpha * 16777216
		end
		for pixelIndex = 0, pixelCount - 1 do
			local paletteIndex = bufferReadU8(scanlines, pixelIndex)
			if paletteIndex >= paletteCount then
				error("PNG palette index is out of range", 0)
			end
			bufferWriteU32(output, pixelIndex * 4, packedPalette[paletteIndex + 1])
		end
	elseif parsed.colorType == 4 then
		for pixelIndex = 0, pixelCount - 1 do
			local sourceOffset = pixelIndex * 2
			local gray = bufferReadU8(scanlines, sourceOffset)
			local alpha = bufferReadU8(scanlines, sourceOffset + 1)
			writeRgba(output, pixelIndex, gray, gray, gray, alpha)
		end
	else
		error("unsupported PNG color type", 0)
	end

	return output
end

local function decodePng(data: string, options: PngDecodeOptions): PngImage
	local parsed = profilePngStage(options, "PNG parse", function(): ParsedPng
		return parsePng(data, options)
	end)
	local channelsByColorType = {
		[0] = 1,
		[2] = 3,
		[3] = 1,
		[4] = 2,
		[6] = 4,
	}
	local channels = channelsByColorType[parsed.colorType]
	if channels == nil then
		error("unsupported PNG color type", 0)
	end

	local rowBytes = parsed.width * channels
	local inflatedSize = (rowBytes + 1) * parsed.height
	local inflated = profilePngStage(options, "PNG inflate", function(): buffer
		return inflateZlib(parsed.compressedData, inflatedSize, options)
	end)
	profilePngStage(options, "PNG unfilter", function()
		unfilterPng(inflated, parsed.height, rowBytes, channels)
	end)
	local output = profilePngStage(options, "PNG RGBA conversion", function(): buffer
		return convertToRgba(parsed, inflated)
	end)

	return {
		width = parsed.width,
		height = parsed.height,
		pixels = output,
	}
end

local PngDecoder = {}

function PngDecoder.isFormat(data: string): boolean
	return string.sub(data, 1, #PNG_SIGNATURE) == PNG_SIGNATURE
end

function PngDecoder.decode(data: string, config: PngDecodeConfig?): PngImage
	local options: PngDecodeOptions = {
		verifyChecksums = if config == nil or config.verifyChecksums == nil then false else config.verifyChecksums,
		onStage = if config == nil then nil else config.onStage,
	}
	return decodePng(data, options)
end

-- Module: Decoder/Bmp

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

-- Module: Decoder

--!strict


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

-- Module: init


return {
	Request = Request,
	Decoder = Decoder,
}
