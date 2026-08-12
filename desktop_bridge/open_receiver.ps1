param(
  [Parameter(Mandatory=$true)][string]$Server,
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$Token
)
$base=$Server.TrimEnd('/')
$url="$base/viewer?session_id=$([uri]::EscapeDataString($SessionId))&token=$([uri]::EscapeDataString($Token))"
Write-Host "Opening FaceSwap receiver: $base/viewer"
Start-Process $url
