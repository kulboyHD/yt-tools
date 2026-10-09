Add-Type -AssemblyName System.Web
$root = $PSScriptRoot
$port = 8080

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "============================================"
Write-Host "  TikTok Downloader Server (v2)"
Write-Host "  http://localhost:$port/tiktok.html"
Write-Host "============================================"
Write-Host "Press Ctrl+C to stop"
Write-Host ""

$mimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css'
    '.js'   = 'application/javascript'
    '.json' = 'application/json'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.svg'  = 'image/svg+xml'
    '.wasm' = 'application/wasm'
    '.onnx' = 'application/octet-stream'
    '.mp4'  = 'video/mp4'
    '.mp3'  = 'audio/mpeg'
    '.wav'  = 'audio/wav'
    '.webm' = 'video/webm'
}

# Use curl.exe for API calls (better TLS fingerprint, avoids Cloudflare blocks)
function Invoke-TikWMProxy {
    param(
        [string]$ApiPath,
        [string]$Body,
        [string]$Method
    )

    $bases = @(
        "https://www.tikwm.com/"
    )

    foreach ($base in $bases) {
        $url = $base + $ApiPath

        # Try POST with curl.exe
        if ($Method -eq "POST" -and $Body) {
            try {
                Write-Host "  [curl POST] $url"
                $result = & curl.exe -s -X POST $url `
                    -d $Body `
                    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" `
                    -H "Accept: application/json, text/plain, */*" `
                    -H "Accept-Language: en-US,en;q=0.9" `
                    -H "Content-Type: application/x-www-form-urlencoded" `
                    -H "Referer: https://www.tikwm.com/" `
                    -H "Origin: https://www.tikwm.com" `
                    --connect-timeout 15 `
                    --max-time 30 2>&1

                $resultStr = $result -join ""

                if ($resultStr -and $resultStr.StartsWith("{")) {
                    Write-Host "  [curl POST] Success!"
                    return $resultStr
                } else {
                    Write-Host "  [curl POST] Non-JSON response (likely Cloudflare)"
                }
            } catch {
                Write-Host "  [curl POST] Error: $($_.Exception.Message)"
            }
        }

        # Try GET
        try {
            $getUrl = $url
            if ($Body) { $getUrl = $url + "?" + $Body }

            Write-Host "  [curl GET] $getUrl"
            $result = & curl.exe -s $getUrl `
                -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" `
                -H "Accept: application/json, text/plain, */*" `
                -H "Accept-Language: en-US,en;q=0.9" `
                -H "Referer: https://www.tikwm.com/" `
                --connect-timeout 15 `
                --max-time 30 2>&1

            $resultStr = $result -join ""

            if ($resultStr -and $resultStr.StartsWith("{")) {
                Write-Host "  [curl GET] Success!"
                return $resultStr
            } else {
                Write-Host "  [curl GET] Non-JSON response"
            }
        } catch {
            Write-Host "  [curl GET] Error: $($_.Exception.Message)"
        }
    }

    return $null
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    $path = $request.Url.LocalPath
    if ($path -eq '/') { $path = '/tiktok.html' }

    # CORS headers
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    $response.Headers.Add("Access-Control-Allow-Headers", "*")

    # CORS preflight
    if ($request.HttpMethod -eq "OPTIONS") {
        $response.StatusCode = 204
        $response.Close()
        continue
    }

    # ============================================
    # PROXY ENDPOINT: /tikwm-proxy/*
    # ============================================
    if ($path.StartsWith("/tikwm-proxy/")) {
        $apiPath = $path.Substring("/tikwm-proxy/".Length)

        # Read body
        $body = ""
        if ($request.HttpMethod -eq "POST" -and $request.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()
        } elseif ($request.Url.Query) {
            $body = $request.Url.Query.TrimStart('?')
        }

        Write-Host "[PROXY] $($request.HttpMethod) /tikwm-proxy/$apiPath"

        $proxyResult = Invoke-TikWMProxy -ApiPath $apiPath -Body $body -Method $request.HttpMethod

        if ($proxyResult) {
            $response.ContentType = "application/json; charset=utf-8"
            $response.StatusCode = 200
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($proxyResult)
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host "  => 200 OK ($($bytes.Length) bytes)"
        } else {
            $response.StatusCode = 502
            $errorJson = '{"code":-1,"msg":"API blocked by Cloudflare. This endpoint may not be available."}'
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($errorJson)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host "  => 502 Bad Gateway"
        }

        $response.Close()
        continue
    }

    # ============================================
    # VIDEO DOWNLOAD PROXY: /video-proxy/?url=...
    # ============================================
    if ($path -eq "/video-proxy/") {
        $videoUrl = ""
        if ($request.Url.Query) {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $videoUrl = $query["url"]
        }

        if (-not $videoUrl) {
            $response.StatusCode = 400
            $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Missing url parameter"}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            $response.Close()
            continue
        }

        Write-Host "[VIDEO] Downloading: $($videoUrl.Substring(0, [Math]::Min(80, $videoUrl.Length)))..."

        try {
            # Download video via curl (follows redirects, proper TLS)
            $tempFile = [System.IO.Path]::GetTempFileName() + ".mp4"
            $curlArgs = @(
                "-s", "-L", "-o", $tempFile,
                "-H", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "-H", "Referer: https://www.tikwm.com/",
                "--connect-timeout", "30",
                "--max-time", "120",
                $videoUrl
            )
            & curl.exe @curlArgs 2>&1 | Out-Null

            if (Test-Path $tempFile) {
                $fileBytes = [System.IO.File]::ReadAllBytes($tempFile)
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

                if ($fileBytes.Length -gt 1000) {
                    $response.ContentType = "video/mp4"
                    $response.StatusCode = 200
                    $response.ContentLength64 = $fileBytes.Length
                    $response.Headers.Add("Content-Disposition", "attachment; filename=video.mp4")
                    $response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                    $sizeMB = [Math]::Round($fileBytes.Length / 1MB, 1)
                    Write-Host "  => 200 OK (${sizeMB}MB)"
                } else {
                    $response.StatusCode = 502
                    $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Video download failed - empty or too small"}')
                    $response.ContentType = "application/json"
                    $response.ContentLength64 = $msg.Length
                    $response.OutputStream.Write($msg, 0, $msg.Length)
                    Write-Host "  => 502 File too small ($($fileBytes.Length) bytes)"
                }
            } else {
                $response.StatusCode = 502
                $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"curl failed"}')
                $response.ContentType = "application/json"
                $response.ContentLength64 = $msg.Length
                $response.OutputStream.Write($msg, 0, $msg.Length)
                Write-Host "  => 502 curl failed"
            }
        } catch {
            $response.StatusCode = 500
            $errMsg = $_.Exception.Message
            $msg = [System.Text.Encoding]::UTF8.GetBytes("{`"error`":`"$errMsg`"}")
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            Write-Host "  => 500 Error: $errMsg"
        }

        $response.Close()
        continue
    }

    # ============================================
    # TIKTOK CHANNEL PROXY: /tiktok-channel/?username=...&count=...
    # ============================================
    if ($path -eq "/tiktok-channel/") {
        $username = ""
        $count = 20
        if ($request.Url.Query) {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $username = $query["username"]
            if ($query["count"]) { $count = $query["count"] }
        }

        if (-not $username) {
            $response.StatusCode = 400
            $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Missing username parameter"}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            $response.Close()
            continue
        }

        Write-Host "[CHANNEL] Fetching $count videos for: $username"
        try {
            $url = "https://www.tiktok.com/@$($username.TrimStart('@'))"
            $ytdlpArgs = @(
                "--dump-json",
                "--flat-playlist",
                "--playlist-end", $count,
                $url
            )
            $output = & yt-dlp @ytdlpArgs 2>&1
            $jsonOutput = $output | Where-Object { $_ -is [string] -and $_ -match '^{' } | ConvertFrom-Json
            
            $videos = @()
            if ($jsonOutput) {
                foreach ($item in $jsonOutput) {
                    $videos += @{
                        id = $item.id
                        title = $item.title
                        url = $item.url
                        cover = if ($item.thumbnails) { $item.thumbnails[0].url } else { $null }
                        duration = $item.duration
                        plays = $item.view_count
                        likes = $item.like_count
                        comments = $item.comment_count
                    }
                }
            }
            
            $resultObj = @{
                code = 0
                data = @{
                    videos = $videos
                }
            }
            $json = $resultObj | ConvertTo-Json -Depth 10 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json; charset=utf-8"
            $response.StatusCode = 200
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host "  => 200 OK ($($videos.Count) videos found)"
        } catch {
            $response.StatusCode = 500
            $errMsg = $_.Exception.Message -replace '"', '\"' -replace '`n', ' '
            $msg = [System.Text.Encoding]::UTF8.GetBytes("{`"error`":`"$errMsg`"}")
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            Write-Host "  => 500 Error: $errMsg"
        }
        $response.Close()
        continue
    }

    # ============================================
    # FACEBOOK DOWNLOAD PROXY: /fb-download/?url=...&reup=1
    # ============================================
    if ($path -eq "/fb-download/") {
        $videoUrl = ""
        $reup = $false
        if ($request.Url.Query) {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $videoUrl = $query["url"]
            if ($query["reup"] -eq "1") { $reup = $true }
        }

        if (-not $videoUrl) {
            $response.StatusCode = 400
            $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Missing url parameter"}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            $response.Close()
            continue
        }

        Write-Host "[FACEBOOK] Downloading: $videoUrl"
        try {
            $tempId = [Guid]::NewGuid().ToString().Substring(0,8)
            $downloadsDir = Join-Path $root "downloads"
            if (-not (Test-Path $downloadsDir)) { New-Item -ItemType Directory -Path $downloadsDir | Out-Null }
            
            $tempFile = Join-Path $downloadsDir "$tempId.mp4"
            $infoFile = Join-Path $downloadsDir "$tempId.info.json"
            $finalFile = $tempFile

            # Download video and metadata using yt-dlp natively
            $ytdlpArgs = @(
                "--write-info-json",
                "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                "--merge-output-format", "mp4",
                "-o", $tempFile,
                $videoUrl
            )
            & yt-dlp @ytdlpArgs 2>&1 | Out-Null

            if (-not (Test-Path $tempFile)) {
                throw "Download failed by yt-dlp."
            }

            if ($reup) {
                Write-Host "[FACEBOOK] Modifying metadata to bypass Re-up detection..."
                $reupFile = Join-Path $downloadsDir "reup_$tempId.mp4"
                $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $ffmpegArgs = @(
                    "-y", "-i", $tempFile,
                    "-map_metadata", "-1",
                    "-metadata", "creation_time=$currentTime",
                    "-metadata", "title=Facebook Video",
                    "-c:v", "copy",
                    "-c:a", "copy",
                    "-bitexact",
                    $reupFile
                )
                & ffmpeg @ffmpegArgs 2>&1 | Out-Null

                if (Test-Path $reupFile) {
                    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    $finalFile = $reupFile
                }
            }

            $resultObj = @{
                videoUrl = "/downloads/" + [System.IO.Path]::GetFileName($finalFile)
                infoUrl = "/downloads/$tempId.info.json"
            }
            
            $jsonObj = $resultObj | ConvertTo-Json -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonObj)
            $response.ContentType = "application/json; charset=utf-8"
            $response.StatusCode = 200
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host "  => 200 OK (Returned JSON payload)"

        } catch {
            $response.StatusCode = 500
            $errMsg = Add-Type -AssemblyName System.Web
$root = $PSScriptRoot
$port = 8080

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "============================================"
Write-Host "  TikTok Downloader Server (v2)"
Write-Host "  http://localhost:$port/tiktok.html"
Write-Host "============================================"
Write-Host "Press Ctrl+C to stop"
Write-Host ""

$mimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css'
    '.js'   = 'application/javascript'
    '.json' = 'application/json'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.svg'  = 'image/svg+xml'
    '.wasm' = 'application/wasm'
    '.onnx' = 'application/octet-stream'
    '.mp4'  = 'video/mp4'
    '.mp3'  = 'audio/mpeg'
    '.wav'  = 'audio/wav'
    '.webm' = 'video/webm'
}

# Use curl.exe for API calls (better TLS fingerprint, avoids Cloudflare blocks)
function Invoke-TikWMProxy {
    param(
        [string]$ApiPath,
        [string]$Body,
        [string]$Method
    )

    $bases = @(
        "https://www.tikwm.com/"
    )

    foreach ($base in $bases) {
        $url = $base + $ApiPath

        # Try POST with curl.exe
        if ($Method -eq "POST" -and $Body) {
            try {
                Write-Host "  [curl POST] $url"
                $result = & curl.exe -s -X POST $url `
                    -d $Body `
                    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" `
                    -H "Accept: application/json, text/plain, */*" `
                    -H "Accept-Language: en-US,en;q=0.9" `
                    -H "Content-Type: application/x-www-form-urlencoded" `
                    -H "Referer: https://www.tikwm.com/" `
                    -H "Origin: https://www.tikwm.com" `
                    --connect-timeout 15 `
                    --max-time 30 2>&1

                $resultStr = $result -join ""

                if ($resultStr -and $resultStr.StartsWith("{")) {
                    Write-Host "  [curl POST] Success!"
                    return $resultStr
                } else {
                    Write-Host "  [curl POST] Non-JSON response (likely Cloudflare)"
                }
            } catch {
                Write-Host "  [curl POST] Error: $($_.Exception.Message)"
            }
        }

        # Try GET
        try {
            $getUrl = $url
            if ($Body) { $getUrl = $url + "?" + $Body }

            Write-Host "  [curl GET] $getUrl"
            $result = & curl.exe -s $getUrl `
                -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" `
                -H "Accept: application/json, text/plain, */*" `
                -H "Accept-Language: en-US,en;q=0.9" `
                -H "Referer: https://www.tikwm.com/" `
                --connect-timeout 15 `
                --max-time 30 2>&1

            $resultStr = $result -join ""

            if ($resultStr -and $resultStr.StartsWith("{")) {
                Write-Host "  [curl GET] Success!"
                return $resultStr
            } else {
                Write-Host "  [curl GET] Non-JSON response"
            }
        } catch {
            Write-Host "  [curl GET] Error: $($_.Exception.Message)"
        }
    }

    return $null
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    $path = $request.Url.LocalPath
    if ($path -eq '/') { $path = '/tiktok.html' }

    # CORS headers
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    $response.Headers.Add("Access-Control-Allow-Headers", "*")

    # CORS preflight
    if ($request.HttpMethod -eq "OPTIONS") {
        $response.StatusCode = 204
        $response.Close()
        continue
    }

    # ============================================
    # PROXY ENDPOINT: /tikwm-proxy/*
    # ============================================
    if ($path.StartsWith("/tikwm-proxy/")) {
        $apiPath = $path.Substring("/tikwm-proxy/".Length)

        # Read body
        $body = ""
        if ($request.HttpMethod -eq "POST" -and $request.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()
        } elseif ($request.Url.Query) {
            $body = $request.Url.Query.TrimStart('?')
        }

        Write-Host "[PROXY] $($request.HttpMethod) /tikwm-proxy/$apiPath"

        $proxyResult = Invoke-TikWMProxy -ApiPath $apiPath -Body $body -Method $request.HttpMethod

        if ($proxyResult) {
            $response.ContentType = "application/json; charset=utf-8"
            $response.StatusCode = 200
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($proxyResult)
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host "  => 200 OK ($($bytes.Length) bytes)"
        } else {
            $response.StatusCode = 502
            $errorJson = '{"code":-1,"msg":"API blocked by Cloudflare. This endpoint may not be available."}'
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($errorJson)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host "  => 502 Bad Gateway"
        }

        $response.Close()
        continue
    }

    # ============================================
    # VIDEO DOWNLOAD PROXY: /video-proxy/?url=...
    # ============================================
    if ($path -eq "/video-proxy/") {
        $videoUrl = ""
        if ($request.Url.Query) {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $videoUrl = $query["url"]
        }

        if (-not $videoUrl) {
            $response.StatusCode = 400
            $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Missing url parameter"}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            $response.Close()
            continue
        }

        Write-Host "[VIDEO] Downloading: $($videoUrl.Substring(0, [Math]::Min(80, $videoUrl.Length)))..."

        try {
            # Download video via curl (follows redirects, proper TLS)
            $tempFile = [System.IO.Path]::GetTempFileName() + ".mp4"
            $curlArgs = @(
                "-s", "-L", "-o", $tempFile,
                "-H", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "-H", "Referer: https://www.tikwm.com/",
                "--connect-timeout", "30",
                "--max-time", "120",
                $videoUrl
            )
            & curl.exe @curlArgs 2>&1 | Out-Null

            if (Test-Path $tempFile) {
                $fileBytes = [System.IO.File]::ReadAllBytes($tempFile)
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

                if ($fileBytes.Length -gt 1000) {
                    $response.ContentType = "video/mp4"
                    $response.StatusCode = 200
                    $response.ContentLength64 = $fileBytes.Length
                    $response.Headers.Add("Content-Disposition", "attachment; filename=video.mp4")
                    $response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                    $sizeMB = [Math]::Round($fileBytes.Length / 1MB, 1)
                    Write-Host "  => 200 OK (${sizeMB}MB)"
                } else {
                    $response.StatusCode = 502
                    $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Video download failed - empty or too small"}')
                    $response.ContentType = "application/json"
                    $response.ContentLength64 = $msg.Length
                    $response.OutputStream.Write($msg, 0, $msg.Length)
                    Write-Host "  => 502 File too small ($($fileBytes.Length) bytes)"
                }
            } else {
                $response.StatusCode = 502
                $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"curl failed"}')
                $response.ContentType = "application/json"
                $response.ContentLength64 = $msg.Length
                $response.OutputStream.Write($msg, 0, $msg.Length)
                Write-Host "  => 502 curl failed"
            }
        } catch {
            $response.StatusCode = 500
            $errMsg = $_.Exception.Message
            $msg = [System.Text.Encoding]::UTF8.GetBytes("{`"error`":`"$errMsg`"}")
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            Write-Host "  => 500 Error: $errMsg"
        }

        $response.Close()
        continue
    }

    # ============================================
    # TIKTOK CHANNEL PROXY: /tiktok-channel/?username=...&count=...
    # ============================================
    if ($path -eq "/tiktok-channel/") {
        $username = ""
        $count = 20
        if ($request.Url.Query) {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $username = $query["username"]
            if ($query["count"]) { $count = $query["count"] }
        }

        if (-not $username) {
            $response.StatusCode = 400
            $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Missing username parameter"}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            $response.Close()
            continue
        }

        Write-Host "[CHANNEL] Fetching $count videos for: $username"
        try {
            $url = "https://www.tiktok.com/@$($username.TrimStart('@'))"
            $ytdlpArgs = @(
                "--dump-json",
                "--flat-playlist",
                "--playlist-end", $count,
                $url
            )
            $output = & yt-dlp @ytdlpArgs 2>&1
            $jsonOutput = $output | Where-Object { $_ -is [string] -and $_ -match '^{' } | ConvertFrom-Json
            
            $videos = @()
            if ($jsonOutput) {
                foreach ($item in $jsonOutput) {
                    $videos += @{
                        id = $item.id
                        title = $item.title
                        url = $item.url
                        cover = if ($item.thumbnails) { $item.thumbnails[0].url } else { $null }
                        duration = $item.duration
                        plays = $item.view_count
                        likes = $item.like_count
                        comments = $item.comment_count
                    }
                }
            }
            
            $resultObj = @{
                code = 0
                data = @{
                    videos = $videos
                }
            }
            $json = $resultObj | ConvertTo-Json -Depth 10 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json; charset=utf-8"
            $response.StatusCode = 200
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host "  => 200 OK ($($videos.Count) videos found)"
        } catch {
            $response.StatusCode = 500
            $errMsg = $_.Exception.Message -replace '"', '\"' -replace '`n', ' '
            $msg = [System.Text.Encoding]::UTF8.GetBytes("{`"error`":`"$errMsg`"}")
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            Write-Host "  => 500 Error: $errMsg"
        }
        $response.Close()
        continue
    }

    # ============================================
    # FACEBOOK DOWNLOAD PROXY: /fb-download/?url=...&reup=1
    # ============================================
    if ($path -eq "/fb-download/") {
        $videoUrl = ""
        $reup = $false
        if ($request.Url.Query) {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $videoUrl = $query["url"]
            if ($query["reup"] -eq "1") { $reup = $true }
        }

        if (-not $videoUrl) {
            $response.StatusCode = 400
            $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Missing url parameter"}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            $response.Close()
            continue
        }

        Write-Host "[FACEBOOK] Downloading: $videoUrl"
        try {
            $tempId = [Guid]::NewGuid().ToString().Substring(0,8)
            $tempFile = [System.IO.Path]::GetTempFileName() + "_$tempId.mp4"
            $finalFile = $tempFile

            # Extract title and description
            $titleOutput = & .\yt-dlp.exe --print "%(description)s" $videoUrl 2>&1
            $fullTitle = $titleOutput -join " "
            if ([string]::IsNullOrWhiteSpace($fullTitle) -or $fullTitle -match "ERROR") {
                $fullTitle = "Facebook Video $tempId"
            }
            $fullTitle = $fullTitle.Trim()
            
            # Avoid HTTP header newline injection
            $safeTitle = $fullTitle -replace '
', ' ' -replace '
', ' '
            if ($safeTitle.Length -gt 1500) { $safeTitle = $safeTitle.Substring(0, 1500) }
            
            Write-Host "  -> Title: $safeTitle"

            # Download using yt-dlp
            $ytdlpArgs = @(
                "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                "--merge-output-format", "mp4",
                "-o", $tempFile,
                $videoUrl
            )
            & .\yt-dlp.exe @ytdlpArgs 2>&1 | Out-Null

            if (-not (Test-Path $tempFile)) {
                throw "Download failed by yt-dlp."
            }

            if ($reup) {
                Write-Host "[FACEBOOK] Modifying metadata to bypass Re-up detection..."
                $reupFile = [System.IO.Path]::GetTempFileName() + "_reup_$tempId.mp4"
                # Remove all metadata, set creation_time to current, copy streams
                $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $ffmpegArgs = @(
                    "-y", "-i", $tempFile,
                    "-map_metadata", "-1",
                    "-metadata", "creation_time=$currentTime",
                    "-metadata", "title=Facebook Video",
                    "-c:v", "copy",
                    "-c:a", "copy",
                    "-bitexact",
                    $reupFile
                )
                & ffmpeg @ffmpegArgs 2>&1 | Out-Null

                if (Test-Path $reupFile) {
                    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    $finalFile = $reupFile
                }
            }

            $fileBytes = [System.IO.File]::ReadAllBytes($finalFile)
            Remove-Item $finalFile -Force -ErrorAction SilentlyContinue

            if ($fileBytes.Length -gt 1000) {
                $response.ContentType = "video/mp4"
                $response.StatusCode = 200
                $response.ContentLength64 = $fileBytes.Length
                $response.Headers.Add("Content-Disposition", "attachment; filename=facebook_video.mp4")
                # Add title to header
                $response.Headers.Add("X-Video-Title", [uri]::EscapeDataString($safeTitle))
                $response.Headers.Add("Access-Control-Expose-Headers", "X-Video-Title")
                
                $response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                $sizeMB = [Math]::Round($fileBytes.Length / 1MB, 1)
                Write-Host "  => 200 OK (${sizeMB}MB)"
            } else {
                throw "File is too small or empty."
            }

        } catch {
            $response.StatusCode = 500
            $errMsg = $_.Exception.Message -replace '"', '\"' -replace '
', ' '
            $msg = [System.Text.Encoding]::UTF8.GetBytes("{`"error`":`"$errMsg`"}")
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            Write-Host "  => 500 Error: $errMsg"
        }
        $response.Close()
        continue
    }
    # ============================================
    # STATIC FILE SERVING
    # ============================================
    $filePath = Join-Path $root $path.TrimStart('/')

    if (Test-Path $filePath) {
        $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
        $contentType = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { 'application/octet-stream' }
        $response.ContentType = $contentType
        $response.StatusCode = 200

        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        Write-Host "200 $path"
    } else {
        $response.StatusCode = 404
        $msg = [System.Text.Encoding]::UTF8.GetBytes("Not Found: $path")
        $response.OutputStream.Write($msg, 0, $msg.Length)
        Write-Host "404 $path"
    }

    $response.Close()
}






.Exception.Message -replace '"', '\"' -replace '`n', ' '
            $msg = [System.Text.Encoding]::UTF8.GetBytes("{\"error\":\"$errMsg\"}")
            $response.ContentType = "application/json"
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
            Write-Host "  => 500 Error: $errMsg"
        }
        $response.Close()
        continue
    }
    # ============================================
    # STATIC FILE SERVING
    # ============================================
    $filePath = Join-Path $root $path.TrimStart('/')

    if (Test-Path $filePath) {
        $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
        $contentType = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { 'application/octet-stream' }
        $response.ContentType = $contentType
        $response.StatusCode = 200

        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        Write-Host "200 $path"
    } else {
        $response.StatusCode = 404
        $msg = [System.Text.Encoding]::UTF8.GetBytes("Not Found: $path")
        $response.OutputStream.Write($msg, 0, $msg.Length)
        Write-Host "404 $path"
    }

    $response.Close()
}







