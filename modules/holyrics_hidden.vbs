Option Explicit
' wscript is a GUI executable; Run(..., 0, True) keeps curl's console hidden.
' Waiting happens in this helper process, never in the REAPER script.
Dim shell, args, command, result
Set args = WScript.Arguments
If args.Count <> 4 Then WScript.Quit 2
Function Quoted(value)
  Quoted = Chr(34) & value & Chr(34)
End Function
Set shell = CreateObject("WScript.Shell")
command = Quoted(args(0)) & " --silent --connect-timeout 1 --max-time 2" _
  & " --request POST --header " & Quoted("Content-Type: application/json") _
  & " --data-binary " & Quoted("@" & args(1)) _
  & " --output " & Quoted(args(2)) & " " & Quoted(args(3))
result = shell.Run(command, 0, True)
WScript.Quit result
