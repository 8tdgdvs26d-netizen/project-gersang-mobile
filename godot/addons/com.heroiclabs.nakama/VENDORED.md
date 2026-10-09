# Vendored: Nakama Godot SDK

- Source: https://github.com/heroiclabs/nakama-godot
- Tag: v3.4.0 (commit 14b7f7078a9822c15b0424624e4c883c87730cee)
- License: Apache-2.0 (LICENSE in this folder)
- Copied unmodified, except these paths left out because VS-01 WP01 does not
  use them: `Satori/`, `Satori.gd` (Satori live-ops client) and
  `dotnet-utils/` (C# helpers; this project is GDScript).
- Not registered as an autoload. `godot/scripts/online_progress_client.gd`
  creates the HTTP adapter and client it needs directly.

Verify an unmodified copy:

    diff -r --exclude Satori --exclude Satori.gd --exclude dotnet-utils <nakama-godot v3.4.0>/addons/com.heroiclabs.nakama godot/addons/com.heroiclabs.nakama
