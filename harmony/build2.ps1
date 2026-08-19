$env:PATH = "C:\Program Files\Huawei\DevEco Studio\jbr\bin;$env:PATH"
$env:JAVA_HOME = "C:\Program Files\Huawei\DevEco Studio\jbr"
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"

Set-Location $PSScriptRoot
$buildLog = Join-Path $PSScriptRoot "build_output5.log"
& "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" --no-daemon --mode module -p module=entry -p buildMode=debug assembleHap 2>&1 | Tee-Object -FilePath $buildLog
$buildExitCode = $LASTEXITCODE
Write-Output "EXIT CODE: $buildExitCode"
exit $buildExitCode
