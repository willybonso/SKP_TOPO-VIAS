$ErrorActionPreference = 'Stop'

$pluginName = 'skp_topo_vias'
$sourceLoader = Join-Path $PSScriptRoot 'skp_topo_vias.rb'
$sourcePlugin = Join-Path $PSScriptRoot $pluginName
$pluginsPath = 'C:\Users\Pc\AppData\Roaming\SketchUp\SketchUp 2026\SketchUp\Plugins'
$destinationLoader = Join-Path $pluginsPath 'skp_topo_vias.rb'
$destinationPlugin = Join-Path $pluginsPath $pluginName
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$stagedPlugin = Join-Path $pluginsPath "$pluginName.installing-$timestamp"
$backupPlugin = Join-Path $pluginsPath "$pluginName.backup-$timestamp"
$backupLoader = Join-Path $pluginsPath "skp_topo_vias.rb.backup-$timestamp"
$hadPlugin = Test-Path -LiteralPath $destinationPlugin
$hadLoader = Test-Path -LiteralPath $destinationLoader
$pluginMovedToBackup = $false
$loaderMovedToBackup = $false
$newPluginInstalled = $false

try {
    if (-not (Test-Path -LiteralPath $sourceLoader -PathType Leaf)) {
        throw "No se encontró el cargador del plugin: $sourceLoader"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $sourcePlugin 'main.rb') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $sourcePlugin 'ui\dialog.html') -PathType Leaf)) {
        throw "La carpeta fuente del plugin está incompleta: $sourcePlugin"
    }

    if (-not (Test-Path -LiteralPath $pluginsPath -PathType Container)) {
        New-Item -ItemType Directory -Path $pluginsPath -Force | Out-Null
    }

    Copy-Item -LiteralPath $sourcePlugin -Destination $stagedPlugin -Recurse

    if ($hadPlugin) {
        Move-Item -LiteralPath $destinationPlugin -Destination $backupPlugin
        $pluginMovedToBackup = $true
    }
    if ($hadLoader) {
        Move-Item -LiteralPath $destinationLoader -Destination $backupLoader
        $loaderMovedToBackup = $true
    }

    Move-Item -LiteralPath $stagedPlugin -Destination $destinationPlugin
    $newPluginInstalled = $true
    Copy-Item -LiteralPath $sourceLoader -Destination $destinationLoader

    Write-Host ''
    Write-Host 'Plugin instalado o actualizado correctamente.' -ForegroundColor Green
    Write-Host "Ubicación: $pluginsPath"
    Write-Host 'Reinicia SketchUp 2026 para cargar la versión instalada.'
    if ($pluginMovedToBackup -or $loaderMovedToBackup) {
        Write-Host "Copia de seguridad anterior: $backupPlugin y/o $backupLoader"
    }
}
catch {
    if (Test-Path -LiteralPath $stagedPlugin) {
        Remove-Item -LiteralPath $stagedPlugin -Recurse -Force
    }
    if ($newPluginInstalled -and (Test-Path -LiteralPath $destinationPlugin)) {
        Remove-Item -LiteralPath $destinationPlugin -Recurse -Force
    }
    if ($pluginMovedToBackup -and (Test-Path -LiteralPath $backupPlugin)) {
        Move-Item -LiteralPath $backupPlugin -Destination $destinationPlugin
    }
    if ($loaderMovedToBackup -and (Test-Path -LiteralPath $backupLoader)) {
        if (Test-Path -LiteralPath $destinationLoader) {
            Remove-Item -LiteralPath $destinationLoader -Force
        }
        Move-Item -LiteralPath $backupLoader -Destination $destinationLoader
    }
    Write-Host "No se pudo instalar el plugin: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
