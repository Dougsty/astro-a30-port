# Same build on Windows (needs the .NET 8 SDK). Uses the icons already in A30Control/Assets.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
dotnet run --project A30Kit.SelfTest
dotnet publish A30Control/A30Control.csproj -c Release -r win-x64 --self-contained `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o dist
