# LuauImage

LuauImage can fetch image data from an HTTP(S) URL, decode it into RGBA pixels, and write the result to a Roblox `EditableImage`.

## Supported formats

- PNG: Non-interlaced, 8-bit images
- BMP: Uncompressed 24-bit and 32-bit images

## Usage

Embed `Image.luau` in your project or download it through a request at runtime and execute it using `loadstring`. 

```lua
local url = "https://example.com/image.png"

local fetched = LuauImage.Request.fetch(url)
if not fetched.ok then
	error(fetched.error)
end

local decoded = LuauImage.Decoder.decode(fetched.body)
if not decoded.ok then
	error(decoded.error)
end

local image = decoded.image
local editableImage = game:GetService("AssetService"):CreateEditableImage({
	Size = Vector2.new(image.width, image.height),
})
editableImage:WritePixelsBuffer(
	Vector2.zero,
	Vector2.new(image.width, image.height),
	image.pixels
)

local imageLabel = Instance.new("ImageLabel")
imageLabel.Size = UDim2.fromOffset(image.width, image.height)
imageLabel.ImageContent = Content.fromObject(editableImage)
imageLabel.Parent = script.Parent
```

`Decoder.decode` takes image bytes and returns an RGBA image buffer or an error. Checksum verification is disabled by default. It can be enabled through the decoder options:

```lua
LuauImage.Decoder.decode(bytes, { verifyChecksums = true })
```

Creating and displaying an `EditableImage` requires Roblox support and permission to use editable images in the experience.

## Roadmap

- Profile and optimize PNG/BMP decoding.
- Add more image formats. JPEG, GIF, and WebP are candidates.
- Expand decoder tests as more formats are added.