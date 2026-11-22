' Starts the Zonos3 TTS server inside WSL at Windows logon, with no console window
' and no terminal left open. Safe to run repeatedly: the server script exits
' immediately if the server is already answering on its port.
'
' Where to put this file:
'   press Win+R, type  shell:startup  , Enter, and drop this .vbs in the folder
'   that opens ( %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup )
'
' Does not care where the bundle was unzipped: it searches the WSL home folder for
' zonos3_server.sh (up to four levels deep) and runs whichever copy it finds, in "lazy"
' mode, so no model is loaded until something actually asks for speech.
'
' If the WSL distro is not named "Ubuntu", change the distro line below.
' Progress goes to ~/zonos3-autostart.log inside WSL.

Dim shell, distro, inner, cmd

Set shell = CreateObject("WScript.Shell")

distro = "Ubuntu"

inner = "l=$HOME/zonos3-autostart.log; " & _
        "s=$(find $HOME -maxdepth 4 -name zonos3_server.sh -print -quit 2>/dev/null); " & _
        "if [ -n ""$s"" ]; then echo ""$(date) starting $s"" >>$l; bash ""$s"" lazy >>$l 2>&1; " & _
        "else echo ""$(date) zonos3_server.sh not found under $HOME"" >>$l; fi"

cmd = "wsl.exe -d " & distro & " -- bash -lc """ & inner & """"

' 0 = hidden window, False = do not wait for it to finish
shell.Run cmd, 0, False
