Attribute VB_Name = "modHash"
Option Explicit

''
'' CRC-32 calculation by CatsTail
''
'' Recover CRC by Alex Dragokas (algorithm - Anarchriz). Thanks for help to Riuson.
''

Private Const MAX_HASH_FILE_SIZE As Currency = 10485760@ '10 MB. (maximum file size to calculate hash)

Private Const poly As Long = &HEDB88320

Private Declare Function Mul Lib "msvbvm60.dll" Alias "_allmul" (ByVal dw1 As Long, ByVal Reserved As Long, ByVal dw3 As Long, ByVal Reserved As Long) As Long
Private Declare Function CryptAcquireContext Lib "advapi32.dll" Alias "CryptAcquireContextW" (ByRef phProv As Long, ByVal pszContainer As Long, ByVal pszProvider As Long, ByVal dwProvType As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptCreateHash Lib "advapi32.dll" (ByVal hProv As Long, ByVal Algid As Long, ByVal hKey As Long, ByVal dwFlags As Long, ByRef phHash As Long) As Long
Private Declare Function CryptDestroyHash Lib "advapi32.dll" (ByVal hHash As Long) As Long
Private Declare Function CryptGetHashParam Lib "advapi32.dll" (ByVal pCryptHash As Long, ByVal dwParam As Long, ByRef pbData As Any, ByRef pcbData As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptHashData_Array Lib "advapi32.dll" Alias "CryptHashData" (ByVal hHash As Long, pbData As Any, ByVal dwDataLen As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptHashData_Str Lib "advapi32.dll" Alias "CryptHashData" (ByVal hHash As Long, ByVal pbData As String, ByVal dwDataLen As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptReleaseContext Lib "advapi32.dll" (ByVal hProv As Long, ByVal dwFlags As Long) As Long
Private Declare Function CloseHandle Lib "kernel32.dll" (ByVal hObject As Long) As Long

Private CRC_32_Tab(0 To 255)    As Long
Private pTable(255)             As Long

Private Const ALG_TYPE_ANY As Long = 0
Private Const ALG_SID_MD5 As Long = 3
Private Const ALG_CLASS_HASH As Long = 32768

Private Const HP_HASHVAL As Long = 2
Private Const HP_HASHSIZE As Long = 4

Private Const CRYPT_VERIFYCONTEXT = &HF0000000

Private Const PROV_RSA_FULL As Long = 1
Private Const MS_ENHANCED_PROV As String = "Microsoft Enhanced Cryptographic Provider v1.0"

Public Function GetFileMD5(sFileName$, Optional lFileSize&, Optional JustMD5 As Boolean) As String
    On Error GoTo ErrorHandler:
    
    AppendErrorLogCustom "GetFileMD5 - Begin", "File: " & sFileName
    
    Dim ff          As Long
    Dim hCrypt      As Long
    Dim hHash       As Long
    Dim uMD5(255)   As Byte
    Dim lMD5Len     As Long
    Dim i           As Long
    Dim sMD5        As String
    Dim aBuf()      As Byte
    Dim OldRedir    As Boolean
    Dim Redirect    As Boolean

    Redirect = ToggleWow64FSRedirection(False, sFileName, OldRedir)
    
    If Not OpenW(sFileName, FOR_READ, ff) Then GoTo Finalize
    
    If lFileSize = 0 Then lFileSize = LOFW(ff)
    If lFileSize = 0 Then
        'speed tweak :) 0-byte file always has the same MD5
        If JustMD5 Then
            GetFileMD5 = "D41D8CD98F00B204E9800998ECF8427E"
        Else
            GetFileMD5 = " (size: 0 bytes, MD5: D41D8CD98F00B204E9800998ECF8427E)"
        End If
        GoTo Finalize
    End If
    If lFileSize > MAX_HASH_FILE_SIZE Then
        If Not JustMD5 Then
            GetFileMD5 = " (size: " & lFileSize & " bytes)"
        End If
        GoTo Finalize
    End If
    
    ReDim aBuf(lFileSize - 1)
    If ff <> 0 And ff <> -1 Then
      GetW ff, 1&, , VarPtr(aBuf(0)), CLng(lFileSize)
      CloseW ff
    End If
    
    DoEvents

    frmMain.lblMD5.Caption = "Calculating checksum of " & sFileName & "..."
    
    ToggleWow64FSRedirection True
    
    If CryptAcquireContext(hCrypt, 0&, StrPtr(MS_ENHANCED_PROV), PROV_RSA_FULL, CRYPT_VERIFYCONTEXT) <> 0 Then

        If CryptCreateHash(hCrypt, ALG_TYPE_ANY Or ALG_CLASS_HASH Or ALG_SID_MD5, 0, 0, hHash) <> 0 Then

            If CryptHashData_Array(hHash, aBuf(0), lFileSize, 0) <> 0 Then

                If CryptGetHashParam(hHash, HP_HASHSIZE, uMD5(0), UBound(uMD5) + 1, 0) <> 0 Then

                    lMD5Len = uMD5(0)
                    If CryptGetHashParam(hHash, HP_HASHVAL, uMD5(0), UBound(uMD5) + 1, 0) <> 0 Then

                        For i = 0 To lMD5Len - 1
                            sMD5 = sMD5 & Right$("0" & Hex(uMD5(i)), 2)
                        Next i
                    End If
                End If
            End If
            CryptDestroyHash hHash
        End If
        CryptReleaseContext hCrypt, 0&
        
    Else
        ErrorMsg Err, "modMD5_GetFileMD5", "File: ", sFileName$, "Handle: ", ff, "Size: ", lFileSize
    End If
    
    If Len(sMD5) <> 0 Then
        If JustMD5 Then
            GetFileMD5 = sMD5
        Else
            GetFileMD5 = " (size: " & lFileSize & " bytes, MD5: " & sMD5 & ")"
        End If
    Else
        If Not JustMD5 Then
            GetFileMD5 = " (size: " & lFileSize & " bytes)"
        End If
    End If
    
    DoEvents
    
Finalize:
    If Redirect Then Call ToggleWow64FSRedirection(OldRedir)
    frmMain.lblMD5.Caption = ""
    
    AppendErrorLogCustom "GetFileMD5 - End"
    Exit Function
ErrorHandler:
    ErrorMsg Err, "modMD5_GetFileMD5", "File: ", sFileName$, "Handle: ", ff, "Size: ", lFileSize
    If Redirect Then Call ToggleWow64FSRedirection(OldRedir)
    frmMain.lblMD5.Caption = ""
    If inIDE Then Stop: Resume Next
End Function

'Public Sub UpdateMD5Progress(i&, iMax&)
'    With frmMain
'        If i = -1 Then
'            'hide md5 progress bar
'            .shpMD5Background.Visible = False
'            .shpMD5Progress.Width = 15
'            .shpMD5Progress.Visible = False
'            DoEvents
'            Exit Sub
'        ElseIf i = 0 Then
'            'show + reset md5 progress bar
'            .shpMD5Background.Visible = True
'            .shpMD5Progress.Visible = True
'            .shpMD5Progress.Width = 15
'            DoEvents
'            Exit Sub
'        End If
'
'        .shpMD5Progress.Width = .shpMD5Background.Width * (CLng(i) / CLng(iMax))
'
'        DoEvents
'    End With
'End Sub


Public Function Crypt$(sMsg$, sPhrase$, Optional doCrypt As Boolean = False)  'if Crypt = False then we do decryption
    Dim sEncryptionPhrase$
    On Error GoTo ErrorHandler:
    AppendErrorLogCustom "Crypt - Begin"
    
    'if one error happens, don't screw up everything following
    
    'like, NOT!
    sEncryptionPhrase = "FUCK YOU SPYWARENUKER AND BPS SPYWARE REMOVER!"
    
    'bEnOrDec = false -> decrypt
    'bEnOrDec = true -> encrypt
    
    Dim i&, J&, sChar$, iChar&, sOut$
    J = 1
    For i = 1 To Len(sMsg)
        sChar = Mid$(sMsg, i, 1)
        If doCrypt Then
            'encrypt
            sChar = Chr(Asc(sChar) + Asc(Mid$(sPhrase, J, 1)))
            If iChar > 255 Then Exit Function 'Wrong Pass phrase
            If Asc(sChar) > 126 Then
                'make sure encrypted char is within
                'normal range (space to ~)
                sChar = Chr(Asc(sChar) - 94)
            End If
        Else
            'decrypt
            iChar = Asc(sChar) - Asc(Mid$(sPhrase, J, 1))
            If iChar < -94 Then Exit Function 'Wrong Pass phrase
            If iChar < 32 Then
                'make sure decrypted char is within
                'normal range (space to ~)
                sChar = Chr(iChar + 94)
            Else
                'old encrypter doesn't encrypt chars above 126 :(
                If Asc(sChar) < 192 Then
                    sChar = Chr(iChar)
                End If
            End If
        End If
        sOut = sOut & sChar
        J = J + 1
        If J > Len(sPhrase) Then J = 1
    Next i
    Crypt = sOut
    
    AppendErrorLogCustom "Crypt - End"
    Exit Function
ErrorHandler:
    ErrorMsg Err, "Crypt", sMsg
    If inIDE Then Stop: Resume Next
End Function

'::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
'::::::::::::::::              ������ CRC-32               ::::::::::::::::
'::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

':::::::::::::::: ������������������� ������ ������������� ::::::::::::::::

Public Sub CRCinit()

       CRC_32_Tab(0) = &H0
       CRC_32_Tab(1) = &H77073096
       CRC_32_Tab(2) = &HEE0E612C
       CRC_32_Tab(3) = &H990951BA
       CRC_32_Tab(4) = &H76DC419
       CRC_32_Tab(5) = &H706AF48F
       CRC_32_Tab(6) = &HE963A535
       CRC_32_Tab(7) = &H9E6495A3
       CRC_32_Tab(8) = &HEDB8832
       CRC_32_Tab(9) = &H79DCB8A4
       CRC_32_Tab(10) = &HE0D5E91E
       CRC_32_Tab(11) = &H97D2D988
       CRC_32_Tab(12) = &H9B64C2B
       CRC_32_Tab(13) = &H7EB17CBD
       CRC_32_Tab(14) = &HE7B82D07
       CRC_32_Tab(15) = &H90BF1D91
       CRC_32_Tab(16) = &H1DB71064
       CRC_32_Tab(17) = &H6AB020F2
       CRC_32_Tab(18) = &HF3B97148
       CRC_32_Tab(19) = &H84BE41DE
       CRC_32_Tab(20) = &H1ADAD47D
       CRC_32_Tab(21) = &H6DDDE4EB
       CRC_32_Tab(22) = &HF4D4B551
       CRC_32_Tab(23) = &H83D385C7
       CRC_32_Tab(24) = &H136C9856
       CRC_32_Tab(25) = &H646BA8C0
       CRC_32_Tab(26) = &HFD62F97A
       CRC_32_Tab(27) = &H8A65C9EC
       CRC_32_Tab(28) = &H14015C4F
       CRC_32_Tab(29) = &H63066CD9
       CRC_32_Tab(30) = &HFA0F3D63
       CRC_32_Tab(31) = &H8D080DF5
       CRC_32_Tab(32) = &H3B6E20C8
       CRC_32_Tab(33) = &H4C69105E
       CRC_32_Tab(34) = &HD56041E4
       CRC_32_Tab(35) = &HA2677172
       CRC_32_Tab(36) = &H3C03E4D1
       CRC_32_Tab(37) = &H4B04D447
       CRC_32_Tab(38) = &HD20D85FD
       CRC_32_Tab(39) = &HA50AB56B
       CRC_32_Tab(40) = &H35B5A8FA
       CRC_32_Tab(41) = &H42B2986C
       CRC_32_Tab(42) = &HDBBBC9D6
       CRC_32_Tab(43) = &HACBCF940
       CRC_32_Tab(44) = &H32D86CE3
       CRC_32_Tab(45) = &H45DF5C75
       CRC_32_Tab(46) = &HDCD60DCF
       CRC_32_Tab(47) = &HABD13D59
       CRC_32_Tab(48) = &H26D930AC
       CRC_32_Tab(49) = &H51DE003A
       CRC_32_Tab(50) = &HC8D75180
       CRC_32_Tab(51) = &HBFD06116
       CRC_32_Tab(52) = &H21B4F4B5
       CRC_32_Tab(53) = &H56B3C423
       CRC_32_Tab(54) = &HCFBA9599
       CRC_32_Tab(55) = &HB8BDA50F
       CRC_32_Tab(56) = &H2802B89E
       CRC_32_Tab(57) = &H5F058808
       CRC_32_Tab(58) = &HC60CD9B2
       CRC_32_Tab(59) = &HB10BE924
       CRC_32_Tab(60) = &H2F6F7C87
       CRC_32_Tab(61) = &H58684C11
       CRC_32_Tab(62) = &HC1611DAB
       CRC_32_Tab(63) = &HB6662D3D
       CRC_32_Tab(64) = &H76DC4190
       CRC_32_Tab(65) = &H1DB7106
       CRC_32_Tab(66) = &H98D220BC
       CRC_32_Tab(67) = &HEFD5102A
       CRC_32_Tab(68) = &H71B18589
       CRC_32_Tab(69) = &H6B6B51F
       CRC_32_Tab(70) = &H9FBFE4A5
       CRC_32_Tab(71) = &HE8B8D433
       CRC_32_Tab(72) = &H7807C9A2
       CRC_32_Tab(73) = &HF00F934
       CRC_32_Tab(74) = &H9609A88E
       CRC_32_Tab(75) = &HE10E9818
       CRC_32_Tab(76) = &H7F6A0DBB
       CRC_32_Tab(77) = &H86D3D2D
       CRC_32_Tab(78) = &H91646C97
       CRC_32_Tab(79) = &HE6635C01
       CRC_32_Tab(80) = &H6B6B51F4
       CRC_32_Tab(81) = &H1C6C6162
       CRC_32_Tab(82) = &H856530D8
       CRC_32_Tab(83) = &HF262004E
       CRC_32_Tab(84) = &H6C0695ED
       CRC_32_Tab(85) = &H1B01A57B
       CRC_32_Tab(86) = &H8208F4C1
       CRC_32_Tab(87) = &HF50FC457
       CRC_32_Tab(88) = &H65B0D9C6
       CRC_32_Tab(89) = &H12B7E950
       CRC_32_Tab(90) = &H8BBEB8EA
       CRC_32_Tab(91) = &HFCB9887C
       CRC_32_Tab(92) = &H62DD1DDF
       CRC_32_Tab(93) = &H15DA2D49
       CRC_32_Tab(94) = &H8CD37CF3
       CRC_32_Tab(95) = &HFBD44C65
       CRC_32_Tab(96) = &H4DB26158
       CRC_32_Tab(97) = &H3AB551CE
       CRC_32_Tab(98) = &HA3BC0074
       CRC_32_Tab(99) = &HD4BB30E2
       CRC_32_Tab(100) = &H4ADFA541
       CRC_32_Tab(101) = &H3DD895D7
       CRC_32_Tab(102) = &HA4D1C46D
       CRC_32_Tab(103) = &HD3D6F4FB
       CRC_32_Tab(104) = &H4369E96A
       CRC_32_Tab(105) = &H346ED9FC
       CRC_32_Tab(106) = &HAD678846
       CRC_32_Tab(107) = &HDA60B8D0
       CRC_32_Tab(108) = &H44042D73
       CRC_32_Tab(109) = &H33031DE5
       CRC_32_Tab(110) = &HAA0A4C5F
       CRC_32_Tab(111) = &HDD0D7CC9
       CRC_32_Tab(112) = &H5005713C
       CRC_32_Tab(113) = &H270241AA
       CRC_32_Tab(114) = &HBE0B1010
       CRC_32_Tab(115) = &HC90C2086
       CRC_32_Tab(116) = &H5768B525
       CRC_32_Tab(117) = &H206F85B3
       CRC_32_Tab(118) = &HB966D409
       CRC_32_Tab(119) = &HCE61E49F
       CRC_32_Tab(120) = &H5EDEF90E
       CRC_32_Tab(121) = &H29D9C998
       CRC_32_Tab(122) = &HB0D09822
       CRC_32_Tab(123) = &HC7D7A8B4
       CRC_32_Tab(124) = &H59B33D17
       CRC_32_Tab(125) = &H2EB40D81
       CRC_32_Tab(126) = &HB7BD5C3B
       CRC_32_Tab(127) = &HC0BA6CAD
       CRC_32_Tab(128) = &HEDB88320
       CRC_32_Tab(129) = &H9ABFB3B6
       CRC_32_Tab(130) = &H3B6E20C
       CRC_32_Tab(131) = &H74B1D29A
       CRC_32_Tab(132) = &HEAD54739
       CRC_32_Tab(133) = &H9DD277AF
       CRC_32_Tab(134) = &H4DB2615
       CRC_32_Tab(135) = &H73DC1683
       CRC_32_Tab(136) = &HE3630B12
       CRC_32_Tab(137) = &H94643B84
       CRC_32_Tab(138) = &HD6D6A3E
       CRC_32_Tab(139) = &H7A6A5AA8
       CRC_32_Tab(140) = &HE40ECF0B
       CRC_32_Tab(141) = &H9309FF9D
       CRC_32_Tab(142) = &HA00AE27
       CRC_32_Tab(143) = &H7D079EB1
       CRC_32_Tab(144) = &HF00F9344
       CRC_32_Tab(145) = &H8708A3D2
       CRC_32_Tab(146) = &H1E01F268
       CRC_32_Tab(147) = &H6906C2FE
       CRC_32_Tab(148) = &HF762575D
       CRC_32_Tab(149) = &H806567CB
       CRC_32_Tab(150) = &H196C3671
       CRC_32_Tab(151) = &H6E6B06E7
       CRC_32_Tab(152) = &HFED41B76
       CRC_32_Tab(153) = &H89D32BE0
       CRC_32_Tab(154) = &H10DA7A5A
       CRC_32_Tab(155) = &H67DD4ACC
       CRC_32_Tab(156) = &HF9B9DF6F
       CRC_32_Tab(157) = &H8EBEEFF9
       CRC_32_Tab(158) = &H17B7BE43
       CRC_32_Tab(159) = &H60B08ED5
       CRC_32_Tab(160) = &HD6D6A3E8
       CRC_32_Tab(161) = &HA1D1937E
       CRC_32_Tab(162) = &H38D8C2C4
       CRC_32_Tab(163) = &H4FDFF252
       CRC_32_Tab(164) = &HD1BB67F1
       CRC_32_Tab(165) = &HA6BC5767
       CRC_32_Tab(166) = &H3FB506DD
       CRC_32_Tab(167) = &H48B2364B
       CRC_32_Tab(168) = &HD80D2BDA
       CRC_32_Tab(169) = &HAF0A1B4C
       CRC_32_Tab(170) = &H36034AF6
       CRC_32_Tab(171) = &H41047A60
       CRC_32_Tab(172) = &HDF60EFC3
       CRC_32_Tab(173) = &HA867DF55
       CRC_32_Tab(174) = &H316E8EEF
       CRC_32_Tab(175) = &H4669BE79
       CRC_32_Tab(176) = &HCB61B38C
       CRC_32_Tab(177) = &HBC66831A
       CRC_32_Tab(178) = &H256FD2A0
       CRC_32_Tab(179) = &H5268E236
       CRC_32_Tab(180) = &HCC0C7795
       CRC_32_Tab(181) = &HBB0B4703
       CRC_32_Tab(182) = &H220216B9
       CRC_32_Tab(183) = &H5505262F
       CRC_32_Tab(184) = &HC5BA3BBE
       CRC_32_Tab(185) = &HB2BD0B28
       CRC_32_Tab(186) = &H2BB45A92
       CRC_32_Tab(187) = &H5CB36A04
       CRC_32_Tab(188) = &HC2D7FFA7
       CRC_32_Tab(189) = &HB5D0CF31
       CRC_32_Tab(190) = &H2CD99E8B
       CRC_32_Tab(191) = &H5BDEAE1D
       CRC_32_Tab(192) = &H9B64C2B0
       CRC_32_Tab(193) = &HEC63F226
       CRC_32_Tab(194) = &H756AA39C
       CRC_32_Tab(195) = &H26D930A
       CRC_32_Tab(196) = &H9C0906A9
       CRC_32_Tab(197) = &HEB0E363F
       CRC_32_Tab(198) = &H72076785
       CRC_32_Tab(199) = &H5005713
       CRC_32_Tab(200) = &H95BF4A82
       CRC_32_Tab(201) = &HE2B87A14
       CRC_32_Tab(202) = &H7BB12BAE
       CRC_32_Tab(203) = &HCB61B38
       CRC_32_Tab(204) = &H92D28E9B
       CRC_32_Tab(205) = &HE5D5BE0D
       CRC_32_Tab(206) = &H7CDCEFB7
       CRC_32_Tab(207) = &HBDBDF21
       CRC_32_Tab(208) = &H86D3D2D4
       CRC_32_Tab(209) = &HF1D4E242
       CRC_32_Tab(210) = &H68DDB3F8
       CRC_32_Tab(211) = &H1FDA836E
       CRC_32_Tab(212) = &H81BE16CD
       CRC_32_Tab(213) = &HF6B9265B
       CRC_32_Tab(214) = &H6FB077E1
       CRC_32_Tab(215) = &H18B74777
       CRC_32_Tab(216) = &H88085AE6
       CRC_32_Tab(217) = &HFF0F6A70
       CRC_32_Tab(218) = &H66063BCA
       CRC_32_Tab(219) = &H11010B5C
       CRC_32_Tab(220) = &H8F659EFF
       CRC_32_Tab(221) = &HF862AE69
       CRC_32_Tab(222) = &H616BFFD3
       CRC_32_Tab(223) = &H166CCF45
       CRC_32_Tab(224) = &HA00AE278
       CRC_32_Tab(225) = &HD70DD2EE
       CRC_32_Tab(226) = &H4E048354
       CRC_32_Tab(227) = &H3903B3C2
       CRC_32_Tab(228) = &HA7672661
       CRC_32_Tab(229) = &HD06016F7
       CRC_32_Tab(230) = &H4969474D
       CRC_32_Tab(231) = &H3E6E77DB
       CRC_32_Tab(232) = &HAED16A4A
       CRC_32_Tab(233) = &HD9D65ADC
       CRC_32_Tab(234) = &H40DF0B66
       CRC_32_Tab(235) = &H37D83BF0
       CRC_32_Tab(236) = &HA9BCAE53
       CRC_32_Tab(237) = &HDEBB9EC5
       CRC_32_Tab(238) = &H47B2CF7F
       CRC_32_Tab(239) = &H30B5FFE9
       CRC_32_Tab(240) = &HBDBDF21C
       CRC_32_Tab(241) = &HCABAC28A
       CRC_32_Tab(242) = &H53B39330
       CRC_32_Tab(243) = &H24B4A3A6
       CRC_32_Tab(244) = &HBAD03605
       CRC_32_Tab(245) = &HCDD70693
       CRC_32_Tab(246) = &H54DE5729
       CRC_32_Tab(247) = &H23D967BF
       CRC_32_Tab(248) = &HB3667A2E
       CRC_32_Tab(249) = &HC4614AB8
       CRC_32_Tab(250) = &H5D681B02
       CRC_32_Tab(251) = &H2A6F2B94
       CRC_32_Tab(252) = &HB40BBE37
       CRC_32_Tab(253) = &HC30C8EA1
       CRC_32_Tab(254) = &H5A05DF1B
       CRC_32_Tab(255) = &H2D02EF8D
 
End Sub

'::::::::::: ������ ���������� ����� �������� ������ :::::::::::::

Function Shr(n As Long, M As Long) As Long

    Dim Q As Long

         If (M > 31&) Then
            
            Shr = 0
            
            Exit Function
         
         End If

         If (n >= 0) Then
         
            Shr = n \ (2& ^ M)

         Else
         
           Q = n And &H7FFFFFFF
           
           Q = Q \ (2& ^ M)
           
           Shr = Q Or (2& ^ (31& - M))
 
         End If

End Function

'::::::::::::::: ��������� CRC-��� ������ ::::::::::::::::::::

Public Function CalcCRC(Stri As String) As String '// Dragokas - ������� ������� � Hex

    Dim CRC As Long
    Dim i   As Long
    Dim M   As Long
    Dim n   As Long

    CRC = &HFFFFFFFF

    For i = 1& To Len(Stri)

        M = Asc(Mid$(Stri, i&, 1&))

        n = (CRC Xor M&) And &HFF&

        CRC = CRC_32_Tab(n&) Xor (Shr(CRC, 8&) And &HFFFFFF)

    Next i

    CalcCRC = Hex(-(CRC + 1&))

    If Len(CalcCRC) < 8& Then
        CalcCRC = Right$("0000000" & CalcCRC, 8&)
    End If

End Function

'::::::::::::::: ��������� CRC-��� ����� ::::::::::::::::::::

Public Function CalcFileCRC(FileName As String) As String '// Added by Dragokas
    On Error GoTo ErrorHandler

    Dim ff      As Long
    Dim str     As String
    Dim Redirect As Boolean, bOldStatus As Boolean

    Redirect = ToggleWow64FSRedirection(False, FileName, bOldStatus)

    If OpenW(FileName, FOR_READ, ff) Then
        str = String$(LOFW(ff), vbNullChar)
        GetW ff, 1&, str
        CloseW ff: ff = 0
    End If
    
    If Redirect Then Call ToggleWow64FSRedirection(bOldStatus)
    
    If Len(str) <> 0 Then CalcFileCRC = CalcCRC(str)
    Exit Function
ErrorHandler:
    ErrorMsg Err, "CalcFileCRC", "File:", FileName
    If inIDE Then Stop: Resume Next
End Function

'Sub Make_CRC_32_Table()
'    Dim bx&, cx&, eax&
'
'    For bx = 0& To 255&
'        eax = bx
'        For cx = 0& To 7&
'            If (eax And 1) Then
'                eax = ((eax And &HFFFFFFFE) \ 2&) And &H7FFFFFFF    'eax >> 1
'                eax = eax Xor poly
'            Else
'                eax = ((eax And &HFFFFFFFE) \ 2&) And &H7FFFFFFF
'            End If
'        Next
'        Tab_CRC(bx) = eax
'        pTable(((eax And &HFF000000) \ &H1000000) And &HFF) = bx
'    Next
'End Sub

Sub SplitInto4bytes(src As Long, bit3 As Byte, bit2 As Byte, bit1 As Byte, bit0 As Byte)
    bit3 = ((src And &HFF000000) \ &H1000000) And &HFF
    bit2 = ((src And &HFF0000) \ &H10000) And &HFF
    bit1 = ((src And &HFF00) \ &H100) And &HFF
    bit0 = src And &HFF
End Sub

' ��������������� CRC �� ���������.
' ���������� 4 �����, ������� ����� �������� � ����� ������

'Public Function RecoverCRC(InitStri As String, newCRC As Long) As String
Public Function RecoverCRC(ForwardCRC As Long, newCRC As Long) As String
    
    'Dim newCRC&, InitStri$, ForwardCRC&
    Dim oldCRC&, ChkCRC&, a(3) As Byte, b(3) As Byte, c(3) As Byte, d(3) As Byte, e(3) As Byte, F(3) As Byte, r(3) As Byte, i&
    Dim NewStri$, PatchAddr&, BackwardCRC&, AddBytes$
    
    ' �������� ������
    'InitStri = "Some Data"
    
    ' ������� ����� ��� ���������� (��� ����������) ������ (������� � ����).
    'PatchAddr = Len(InitStri) 'Len(InitStri) - ����� � �����
    
    'If PatchAddr > Len(InitStri) Then Err.Raise 14
    
    'Make_CRC_32_Table
    
    ' ����� �� ����� ��������
    'newCRC = &H12345678
    'oldCRC = CalcCRCLong(InitStri)
    
    'Debug.Print "Initial CRC: " & Hex(oldCRC)
    'Debug.Print "New CRC:     " & Hex(newCRC)
    
    'ForwardCRC = CalcCRCLong(Left$(InitStri, PatchAddr)) Xor -1
    BackwardCRC = newCRC Xor -1
    
    'If (PatchAddr + 4) < Len(InitStri) Then BackwardCRC = CalcCRCReverse(Right$(InitStri, Len(InitStri) - (PatchAddr + 4)), BackwardCRC)
    
    SplitInto4bytes ForwardCRC, a(3), a(2), a(1), a(0)
    SplitInto4bytes BackwardCRC, F(3), F(2), F(1), F(0)
    
    e(3) = F(3):                            SplitInto4bytes CRC_32_Tab(pTable(e(3))), e(3), e(2), e(1), e(0)
    d(3) = F(2) Xor e(2):                   SplitInto4bytes CRC_32_Tab(pTable(d(3))), d(3), d(2), d(1), d(0)
    c(3) = F(1) Xor e(1) Xor d(2):          SplitInto4bytes CRC_32_Tab(pTable(c(3))), c(3), c(2), c(1), c(0)
    b(3) = F(0) Xor e(0) Xor d(1) Xor c(2): SplitInto4bytes CRC_32_Tab(pTable(b(3))), b(3), b(2), b(1), b(0)
    
    r(3) = pTable(b(3)) Xor a(0)
    r(2) = pTable(c(3)) Xor b(0) Xor a(1)
    r(1) = pTable(d(3)) Xor c(0) Xor b(1) Xor a(2)
    r(0) = pTable(e(3)) Xor d(0) Xor c(1) Xor b(2) Xor a(3)
    
    AddBytes = Chr$(r(3)) & Chr$(r(2)) & Chr$(r(1)) & Chr$(r(0))
    RecoverCRC = AddBytes
    
    ' ��������� �������������� ����� � �������� ������
    'NewStri = InitStri
    'If PatchAddr - Len(InitStri) + 4 > 0 Then NewStri = NewStri & Space$(PatchAddr - Len(InitStri) + 4)
    'mid$(NewStri, PatchAddr + 1) = Chr$(r(3)) & Chr$(r(2)) & Chr$(r(1)) & Chr$(r(0))
    
    ' ����������� �������� ��
    'ChkCRC = CalcCRCLong(NewStri)
    
    ' ���� �� �� ���������
    'If ChkCRC <> newCRC Then Err.Raise 17
    
    'Debug.Print "Check CRC:   " & Hex(ChkCRC)
    'Debug.Print "�������� ������: " & InitStri
    'Debug.Print "����� ������:    " & NewStri
    'Debug.Print "����� ��� �������: " & PatchAddr
    'Debug.Print "�������������� �����: " & Hex(Mul(r(3), 0, &H1000000, 0) Or Mul(r(2), 0, &H10000, 0) Or Mul(r(1), 0, &H100, 0) Or r(0))
End Function

Public Function CalcCRCLong(Stri As String) As Long
    Dim CRC&, i&, M&, n&

    'If CRC_32_Tab(1) = 0 Then Make_CRC_32_Table

    CRC = -1

    For i = 1& To Len(Stri)
        M = Asc(Mid$(Stri, i, 1&))
        n = (CRC Xor M) And &HFF&
        CRC = (CRC_32_Tab(n) Xor (((CRC And &HFFFFFF00) \ &H100) And &HFFFFFF)) And -1  ' Tab ^ (crc >> 8)
    Next

    CalcCRCLong = -(CRC + 1&)
End Function

Public Function CalcArrayCRCLong(arr() As Byte, Optional prevValue As Long = -1) As Long
    Dim CRC&, i&, M&, n&

    'If CRC_32_Tab(1) = 0 Then Make_CRC_32_Table

    CRC = prevValue

    For i = 0& To UBound(arr)
        M = arr(i)
        n = (CRC Xor M) And &HFF&
        CRC = (CRC_32_Tab(n) Xor (((CRC And &HFFFFFF00) \ &H100) And &HFFFFFF)) And -1  ' Tab ^ (crc >> 8)
    Next

    CalcArrayCRCLong = -(CRC + 1&)
End Function

Public Function CalcCRCReverse(Stri As String, Optional nextValue As Long = -1) As Long
    Dim CRC&, i&, M&, n&, prevValueL&, prevValueH&, b3 As Byte

    'If CRC_32_Tab(1) = 0 Then Make_CRC_32_Table

    CRC = nextValue

    For i = Len(Stri) To 1 Step -1
        M = Asc(Mid$(Stri, i, 1&))
        b3 = ((CRC And &HFF000000) \ &H1000000) And &HFF
        prevValueL = (pTable(b3) Xor M) And &HFF
        prevValueH = Mul(CRC Xor CRC_32_Tab(pTable(b3)), 0, &H100, 0)  ' << 8
        CRC = prevValueH Or prevValueL
    Next
    
    CalcCRCReverse = CRC
End Function

