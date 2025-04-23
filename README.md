# CE Mono/IL2CPP Class Inspector (Lua Script)

**Note:** While this script tries to be resilient, frequent disconnects or crashes might indicate deeper issues with the game's runtime or the MonoDataCollector DLL which this script cannot fix directly. In such cases, using the built-in Mono Dissector or static analysis tools (like Il2CppDumper) is recommended.

## Features

* Simple GUI for class inspection.
* Attempts global class search first, then targets `Assembly-CSharp.dll` if needed.
* Displays fields (static and instance) with offsets, types, and modifiers.
* Displays methods with parameters, return types, and modifiers.
* Uses `pcall` to wrap potentially unstable `monoscript.lua` function calls.
* Attempts to automatically reconnect to the Mono backend if the connection is lost.
* Uses native Lua 5.3+ bitwise operators (`&`).

## Dependencies

* **Cheat Engine 7.5 or later** (uses Lua 5.4 features like the `&` operator).
* **`monoscript.lua`:** Must be present in your Cheat Engine `autorun` directory. This script is included with standard Cheat Engine installations.
* **`MonoDataCollector.dll` / `.so` / `.dylib`:** The corresponding MonoDataCollector library for your CE version and target architecture must be in the correct `autorun/dlls` (or `dylibs`) folder. This is also included with standard Cheat Engine installations.

## Usage

1.  **Save:** Save the Lua script (e.g., `mono_inspector_informal.lua`) anywhere accessible by Cheat Engine.
2.  **Setup CE:** Ensure `monoscript.lua` and the correct `MonoDataCollector` library are in your Cheat Engine `autorun` directories.
3.  **Attach:** Open Cheat Engine and attach it to your target Mono/IL2CPP game.
4.  **Activate Mono:** Use the Cheat Engine menu: `Mono` -> `Activate mono features` (or press `Ctrl+Alt+M`). Wait for confirmation or check the CE console.
5.  **Run Script:** Open the Lua Engine in Cheat Engine (`Table` -> `Show Cheat Table Lua Script`, then click `Execute script`) and run the saved Lua script file.
6.  **Inspect:**
    * The "Mono/IL2CPP Class Inspector" window will appear.
    * Enter the name of the class you want to inspect (e.g., `Player`, `Namespace.ClassName`, `OuterClass+NestedClass`).
    * Click the "Inspect" button or press Enter.
7.  **View Results:** The script will attempt to find the class and display its fields and methods in the text box. It will log connection attempts and errors to the CE Lua console.

## Troubleshooting

* **"monoscript.lua not found" / "key functions are missing":** Ensure `monoscript.lua` is correctly placed in your CE `autorun` folder and is not corrupted.
* **"Failed to establish/re-establish Mono connection":**
    * Make sure you activated Mono features *before* running the script.
    * The target game might be unstable or have anti-cheat measures interfering.
    * There might be a version mismatch between CE, MonoDataCollector, and the game's runtime.
    * Try using the built-in Mono Dissector (`Ctrl+Alt+M`) first. If that *also* fails or crashes, the issue is likely beyond this script.
* **"Error during... search or pipe lost":** This indicates the connection broke during a specific operation. The script attempts to recover, but if it happens repeatedly for a specific class, that class's data might be problematic for the MonoDataCollector to handle. Use the Mono Dissector or static analysis tools.
* **Class Not Found:** Double-check spelling, case sensitivity, namespaces, and the format for nested classes (`Outer+Inner`). Use the Mono Dissector to confirm the exact name.

