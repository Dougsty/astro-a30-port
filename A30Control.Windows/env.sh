# Shared by the build scripts: per-user .NET SDK, and a build snapshot outside iCloud Drive
# (iCloud evicts or touches files mid-build; see A30Control/build.sh).
export DOTNET_ROOT="$HOME/.dotnet" PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
SNAP="$HOME/Library/Caches/A30Control.Windows/src"
mkdir -p "$SNAP"
