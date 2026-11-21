' Starts the Zonos3 TTS server inside WSL at Windows logon, with no console window
' and no terminal left open. Safe to run repeatedly: the server script exits
' immediately if the server is already answering on its port.
'
' Where to put this file:
'   press Win+R, type  shell:startup  , Enter, and drop this .vbs in the folder
'   that opens ( %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup )
'
' Adjust ZONOS_DIR if the bundle lives somewhere other than ~/zonos3 in WSL.

Dim shell, distro, cmd

Set shell = CreateObject("WScript.Shell")

distro = "Ubuntu"
cmd = "wsl.exe -d " & distro & " -- bash -lc ""bash $HOME/zonos3/zonos3_server.sh start >/dev/null 2>&1"""

' 0 = hidden window, False = do not wait for it to finish
shell.Run cmd, 0, False
