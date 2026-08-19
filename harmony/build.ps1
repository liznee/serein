$env:PATH = "C:\Program Files\Huawei\DevEco Studio\jbr\bin;$env:PATH"
$env:JAVA_HOME = "C:\Program Files\Huawei\DevEco Studio\jbr"
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"

Set-Location "C:/workspace/serein\harmony"
# 不 kill daemon——保留编译缓存，增量编译秒出
& "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" --mode module -p module=entry -p buildMode=debug assembleHap 2>&1
Write-Output "EXIT CODE: $LASTEXITCODE"
