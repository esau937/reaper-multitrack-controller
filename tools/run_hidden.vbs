Option Explicit
' Starts the analyser without creating a Command Prompt window.
Dim shell, args, command, i
Set args = WScript.Arguments
If args.Count < 3 Then WScript.Quit 2
Function Quoted(value)
  Quoted = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
command = Quoted(args(0)) & " " & Quoted(args(1))
For i = 2 To args.Count - 1
  command = command & " " & Quoted(args(i))
Next
Set shell = CreateObject("WScript.Shell")
shell.Run command, 0, False
