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

return Request
