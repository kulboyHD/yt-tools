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
Write-Host "  TikTok/Facebook Downloader Server (v3)"
Write-Host "  http://localhost:$port/"
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
    '.txt'  = 'text/plain; charset=utf-8'
}

function Invoke-TikWMProxy {
    param([string]$ApiPath, [string]$Body, [string]$Method)
    $url = "https://www.tikwm.com/" + $ApiPath
    if ($Method -eq "POST" -and $Body) {
        try {
            $result = & curl.exe -s -X POST $url -d $Body -H "User-Agent: Mozilla/5.0" -H "Accept: application/json" -H "Content-Type: application/x-www-form-urlencoded" --connect-timeout 15 --max-time 30 2>&1
            $resultStr = $result -join ""
            if ($resultStr.StartsWith("{")) { return $resultStr }
        } catch {}
    }
    return '{"code":-1,"msg":"Proxy failed"}'
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    $path = $request.Url.AbsolutePath
    
    if ($path -eq "/") { $path = "/index.html" }

    if ($path -eq "/api/") {
        $body = ""
        if ($request.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()
        }
        try {
            $jsonResponse = Invoke-TikWMProxy -ApiPath "api/" -Body $body -Method "POST"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
            $response.ContentType = "application/json; charset=utf-8"
            $response.StatusCode = 200
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch {
            $response.StatusCode = 500
        }
        $response.Close()
        continue
    }

    if ($path -eq "/video-proxy/") {
        $videoUrl = ""
        if ($request.Url.Query) {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $videoUrl = $query["url"]
        }
        if ($videoUrl) {
            try {
                $req = [System.Net.WebRequest]::Create($videoUrl)
                $req.UserAgent = "Mozilla/5.0"
                $res = $req.GetResponse()
                $stream = $res.GetResponseStream()
                $response.ContentType = $res.ContentType
                $response.ContentLength64 = $res.ContentLength
                $buffer = New-Object byte[] 65536
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $response.OutputStream.Write($buffer, 0, $read)
                }
                $stream.Close()
                $res.Close()
            } catch {
                $response.StatusCode = 500
            }
        }
        $response.Close()
        continue
    }

    if ($path -eq "/tiktok-channel/") {
        $username = ""
        $count = 10
        if ($request.Url.Query) {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $username = $query["username"]
            if ($query["count"]) { $count = [int]$query["count"] }
        }
        try {
            $url = "https://www.tiktok.com/@$($username.TrimStart('@'))"
            $ytdlpArgs = @("--impersonate", "chrome", "--dump-json", "--flat-playlist", "--playlist-end", $count, $url)
            $output = & yt-dlp @ytdlpArgs 2>&1
            $jsonOutput = $output | Where-Object { $_ -is [string] -and $_ -match '^{' } | ConvertFrom-Json
            $videos = @()
            if ($jsonOutput) {
                foreach ($item in $jsonOutput) {
                    $videos += @{ id = $item.id; title = $item.title; url = $item.url; cover = if ($item.thumbnails) { $item.thumbnails[0].url } else { $null }; duration = $item.duration }
                }
            }
            $resultObj = @{ code = 0; data = @{ videos = $videos } }
            $json = $resultObj | ConvertTo-Json -Depth 10 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json; charset=utf-8"
            $response.StatusCode = 200
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch { $response.StatusCode = 500 }
        $response.Close()
        continue
    }

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
            $response.Close()
            continue
        }

        try {
            $tempId = [Guid]::NewGuid().ToString().Substring(0,8)
            $downloadsDir = Join-Path $root "downloads"
            if (-not (Test-Path $downloadsDir)) { New-Item -ItemType Directory -Path $downloadsDir | Out-Null }
            
            $tempFile = Join-Path $downloadsDir "$tempId.mp4"
            $infoFile = Join-Path $downloadsDir "$tempId.info.json"
            $finalFile = $tempFile

            $ytdlpArgs = @(
                "--write-info-json",
                "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                "--merge-output-format", "mp4",
                "-o", $tempFile,
                $videoUrl
            )
            & yt-dlp @ytdlpArgs 2>&1 | Out-Null

            if (-not (Test-Path $tempFile)) { throw "Download failed." }

            if ($reup) {
                $reupFile = Join-Path $downloadsDir "reup_$tempId.mp4"
                $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $ffmpegArgs = @(
                    "-y", "-i", $tempFile, "-map_metadata", "-1",
                    "-metadata", "creation_time=$currentTime", "-metadata", "title=Facebook Video",
                    "-c:v", "copy", "-c:a", "copy", "-bitexact", $reupFile
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
        } catch {
            $response.StatusCode = 500
        }
        $response.Close()
        continue
    }

    # STATIC FILE SERVING
    $filePath = Join-Path $root $path.TrimStart('/')
    if (Test-Path $filePath) {
        $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
        $contentType = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { 'application/octet-stream' }
        $response.ContentType = $contentType
        $response.StatusCode = 200
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
        $response.StatusCode = 404
        $msg = [System.Text.Encoding]::UTF8.GetBytes("Not Found: $path")
        $response.OutputStream.Write($msg, 0, $msg.Length)
    }
    $response.Close()
}

