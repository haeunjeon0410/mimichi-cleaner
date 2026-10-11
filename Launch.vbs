' Runs elevated (needed to move Program Files / clean Windows temp). One UAC prompt.
Set fso = CreateObject("Scripting.FileSystemObject")
d = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("Shell.Application").ShellExecute "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & d & "\MimichiCleaner.ps1""", d, "runas", 0
