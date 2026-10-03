Option Explicit
' Uses MSXML2 to send HTTP requests natively without launching curl.exe
' This avoids Windows Defender scanning curl and causing stutters in REAPER.
Dim args, fso, stream, url, body, http, outStream, resultPath
Set args = WScript.Arguments
If args.Count < 4 Then WScript.Quit 2

Dim reqFile, resFile
reqFile = args(1)
resFile = args(2)
url = args(3)

Set fso = CreateObject("Scripting.FileSystemObject")
On Error Resume Next
Set stream = CreateObject("ADODB.Stream")
stream.CharSet = "utf-8"
stream.Open
stream.LoadFromFile reqFile
If Err.Number = 0 Then
  body = stream.ReadText
  stream.Close
Else
  WScript.Quit 3
End If

Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
http.setTimeouts 1000, 1000, 2000, 2000
http.Open "POST", url, False
http.setRequestHeader "Content-Type", "application/json"
http.send body

Dim outStream
Set outStream = CreateObject("ADODB.Stream")
outStream.Type = 2 ' adTypeText
outStream.CharSet = "utf-8"
outStream.Open
If Err.Number = 0 Then
  outStream.WriteText http.responseText
Else
  outStream.WriteText "{""status"":""error"",""message"":""" & Replace(Err.Description, """", "\""") & """}"
End If
outStream.SaveToFile resFile, 2 ' adSaveCreateOverWrite
outStream.Close
WScript.Quit 0
