Attribute VB_Name = "modVerifyDigiSign"
Option Explicit

'
' Authenticode digital signature verifier / Driver's WHQL signature verifier
' revision 2.5. (28.11.2016)
'
' Copyrights: (�) Polshyn Stanislav Viktorovich aka Alex Dragokas
'

'Some code examples:
'https://msdn.microsoft.com/en-us/library/windows/desktop/aa382384%28v=vs.85%29.aspx
'https://support.microsoft.com/en-us/kb/323809
'http://rsdn.org/account/info/69015
'http://rsdn.org/forum/src/3152752.all
'http://processhacker.sourceforge.net/doc/verify_8c_source.html
'http://eternalwindows.jp/crypto/certverify/certverify03.html
'http://forum.sysinternals.com/howto-verify-the-digital-signature-of-a-file_topic19247.html
'http://blog.airesoft.co.uk/code/verifysign.cpp
'http://research32.blogspot.com/2016/03/pe-file-signing.html
'http://download.microsoft.com/download/9/c/5/9c5b2167-8017-4bae-9fde-d599bac8184a/authenticode_pe.docx
'http://stackoverflow.com/questions/24892531/reading-multiple-signatures-from-executable-file

'CERT_CHAIN_POLICY_STATUS structure
'https://msdn.microsoft.com/en-us/library/windows/desktop/aa377188%28v=vs.85%29.aspx?f=255

'Error information:
'https://msdn.microsoft.com/en-us/library/windows/desktop/aa378137(v=vs.85).aspx

'SignerInfo extraction examples:
'https://support.microsoft.com/en-us/kb/323809
'https://www.sysadmins.lv/blog-ru/certificate-trust-list-ctl-v-powershell.aspx
'https://www.sysadmins.lv/blog-ru/chto-v-oide-tebe-moem.aspx
'certmgr.msc
'certmgr.exe (require Windows SDK)

#Const UseHashTable = True ' use hash-tables by ������� �������� ?

Private Const MAX_FILE_SIZE As Currency = 157286400@ '150 MB. limit for file size to check
Private Const MAX_PATH As Long = 260&

Public Type SignResult_TYPE ' out. Digital signature data
    isSigned          As Boolean ' is signed?
    isLegit           As Boolean ' is signature legitimate ?
    isSignedByCert    As Boolean ' is signed by Windows security catalogue ?
    CatalogPath       As String  ' path to catalogue file
    isEmbedded        As Boolean ' is signed by internal (embedded) signature? (SV_CheckEmbeddedPresence flag should be specified)
    isSelfSigned      As Boolean ' is signed by self-signed certificate ?
    AlgorithmCertHash As String  ' hash algorithm of the certificate's signature
    AlgorithmSignDigest As String  ' hash algorithm of the signature's digest
    Issuer            As String  ' certificate's issuer name
    SubjectName       As String  ' signer name
    SubjectEmail      As String  ' signer email
    HashRootCert      As String  ' SHA1 hash of Thumbprint of root certificate in the chain
    HashFileCode      As String  ' Authenticode (PE256) hash of file
    DateCertBegin     As Date    ' certificate is valid since ...
    DateCertExpired   As Date    ' certificate is valid until ...
    NumberOfSigns     As Long    ' number of signatures
    ShortMessage      As String  ' short description of checking results
    FullMessage       As String  ' full description of checking results
    ReturnCode        As String  ' result error code of WinVerifyTrust
    FilePathVerified  As String  ' path to file provided for verification
End Type

Public Enum FLAGS_SignVerify
    SV_CheckRevocation = 1         ' - check whole trust chain for certificate revocation ( require internet connection )
    SV_DisableCatalogVerify = 2    ' - do not use checking by security catalogue ( check internal signature only )
    SV_isDriver = 4                ' - verify WHQL signature of driver
    SV_CacheDoNotLoad = 8          ' - do not read last cached result
    SV_CacheDoNotSave = 16         ' - do not save results of verification to cache (memory savings)
    SV_AllowSelfSigned = 32        ' - self-signed certificates should be considered as legitimate
    SV_AllowExpired = 64           ' - allow signatures with expired date of certificate
    SV_CheckEmbeddedPresence = 128 ' - always check presence of internal signature ( even if verification performed by catalogue )
    SV_CheckSecondarySignature = 256 ' (this flag automatically set SV_DisableCatalogVerify flag)
    SV_NoFileSizeLimit = 512       ' - check file with any size ( default limit = 100 MB. )
End Enum

Private Type GUID
    Data1 As Long
    Data2 As Integer
    Data3 As Integer
    Data4(0 To 7) As Byte
End Type

Private Type SIGNATURE_TYPE
    cCert As Long
    Certificate() As Long
End Type

Private Type CATALOG_INFO
    cbStruct As Long
    wszCatalogFile(MAX_PATH - 1) As Integer
End Type

Private Type WINTRUST_FILE_INFO
    cbStruct             As Long
    pcwszFilePath        As Long
    hFile                As Long
    pgKnownSubject       As Long
End Type

Private Type WINTRUST_CATALOG_INFO
    cbStruct             As Long
    dwCatalogVersion     As Long
    pcwszCatalogFilePath As Long
    pcwszMemberTag       As Long
    pcwszMemberFilePath  As Long
    hMemberFile          As Long
    pbCalculatedFileHash As Long
    cbCalculatedFileHash As Long
    pcCatalogContext     As Long
    hCatAdmin            As Long
End Type

Private Type WINTRUST_DATA
    cbStruct            As Long
    pPolicyCallbackData As Long
    pSIPClientData      As Long
    dwUIChoice          As Long
    fdwRevocationChecks As Long
    dwUnionChoice       As Long
    pUnion              As Long 'ptr to one of 5 structures based on dwUnionChoice param
    dwStateAction       As Long
    hWVTStateData       As Long
    pwszURLReference    As Long
    dwProvFlags         As Long
    dwUIContext         As Long
    pSignatureSettings  As Long 'ptr to WINTRUST_SIGNATURE_SETTINGS (Win8+)
End Type

Private Type WINTRUST_SIGNATURE_SETTINGS
    cbStruct            As Long
    dwIndex             As Long
    dwFlags             As Long
    cSecondarySigs      As Long
    dwVerifiedSigIndex  As Long
    pCryptoPolicy       As Long 'ptr -> CERT_STRONG_SIGN_PARA
End Type

Private Type CERT_STRONG_SIGN_PARA
    cbSize              As Long
    dwInfoChoice        As Long
    pszOID              As Long
End Type

Private Type DRIVER_VER_MAJORMINOR
    dwMajor             As Long
    dwMinor             As Long
End Type

Private Type DRIVER_VER_INFO
    cbStruct            As Long
    dwReserved1         As Long
    dwReserved2         As Long
    dwPlatform          As Long
    dwVersion           As Long
    wszVersion(MAX_PATH - 1)    As Integer
    wszSignedBy(MAX_PATH - 1)   As Integer
    pcSignerCertContext As Long
    sOSVersionLow       As DRIVER_VER_MAJORMINOR
    sOSVersionHigh      As DRIVER_VER_MAJORMINOR
    dwBuildNumberLow    As Long
    dwBuildNumberHigh   As Long
End Type

Private Type FILETIME
    dwLowDateTime       As Long
    dwHighDateTime      As Long
End Type

Private Type SYSTEMTIME
    wYear               As Integer
    wMonth              As Integer
    wDayOfWeek          As Integer
    wDay                As Integer
    wHour               As Integer
    wMinute             As Integer
    wSecond             As Integer
    wMilliseconds       As Integer
End Type

Private Type OSVERSIONINFOEX
    dwOSVersionInfoSize As Long
    dwMajorVersion      As Long
    dwMinorVersion      As Long
    dwBuildNumber       As Long
    dwPlatformId        As Long
    szCSDVersion(255)   As Byte
    wServicePackMajor   As Integer
    wServicePackMinor   As Integer
    wSuiteMask          As Integer
    wProductType        As Byte
    wReserved           As Byte
End Type

Private Type CRYPTOAPI_BLOB
    cbData              As Long
    pbData              As Long ' ptr -> BYTE[]
End Type
'Alias for:
'CRYPT_INTEGER_BLOB, *PCRYPT_INTEGER_BLOB, CRYPT_UINT_BLOB, *PCRYPT_UINT_BLOB, CRYPT_OBJID_BLOB, *PCRYPT_OBJID_BLOB, CERT_NAME_BLOB,
'CERT_RDN_VALUE_BLOB, *PCERT_NAME_BLOB, *PCERT_RDN_VALUE_BLOB, CERT_BLOB, *PCERT_BLOB, CRL_BLOB, *PCRL_BLOB, DATA_BLOB, *PDATA_BLOB,
'CRYPT_DATA_BLOB, *PCRYPT_DATA_BLOB, CRYPT_HASH_BLOB, *PCRYPT_HASH_BLOB, CRYPT_DIGEST_BLOB, *PCRYPT_DIGEST_BLOB, CRYPT_DER_BLOB,
'PCRYPT_DER_BLOB, CRYPT_ATTR_BLOB, *PCRYPT_ATTR_BLOB;

Private Type CRYPT_BIT_BLOB
    cbData              As Long
    pbData              As Long ' ptr -> BYTE[]
    cUnusedBits         As Long
End Type

Private Type CRYPT_ALGORITHM_IDENTIFIER
    pszObjId            As Long ' ptr -> STR
    Parameters          As CRYPTOAPI_BLOB ' CRYPT_OBJID_BLOB
End Type

Private Type CERT_PUBLIC_KEY_INFO
    Algorithm           As CRYPT_ALGORITHM_IDENTIFIER
    PublicKey           As CRYPT_BIT_BLOB
End Type

Private Type CERT_INFO
    dwVersion               As Long
    SerialNumber            As CRYPTOAPI_BLOB ' CERT_NAME_BLOB
    SignatureAlgorithm      As CRYPT_ALGORITHM_IDENTIFIER
    Issuer                  As CRYPTOAPI_BLOB
    NotBefore               As FILETIME
    NotAfter                As FILETIME
    Subject                 As CRYPTOAPI_BLOB
    SubjectPublicKeyInfo    As CERT_PUBLIC_KEY_INFO
    IssuerUniqueId          As CRYPT_BIT_BLOB
    SubjectUniqueId         As CRYPT_BIT_BLOB
    cExtension              As Long
    rgExtension             As Long ' ptr -> CERT_EXTENSION
End Type

Private Type CERT_CONTEXT
    dwCertEncodingType      As Long
    pbCertEncoded           As Long ' ptr -> encoded certificate
    cbCertEncoded           As Long
    pCertInfo               As Long ' ptr -> CERT_INFO
    hCertStore              As Long
End Type

Private Type CRYPT_PROVIDER_CERT
    cbStruct                As Long
    pCert                   As Long ' ptr -> CERT_CONTEXT
    fCommercial             As Long
    fTrustedRoot            As Long
    fSelfSigned             As Long
    fTestCert               As Long
    dwRevokedReason         As Long
    dwConfidence            As Long
    dwError                 As Long
    pTrustListContext       As Long ' ptr -> CTL_CONTEXT
    fTrustListSignerCert    As Long
    pCtlContext             As Long ' ptr -> CTL_CONTEXT
    dwCtlError              As Long
    fIsCyclic               As Long
    pChainElement           As Long ' ptr -> CERT_CHAIN_ELEMENT
End Type

Private Type CRYPT_PROVIDER_SGNR
    cbStruct                As Long
    sftVerifyAsOf           As FILETIME
    csCertChain             As Long
    pasCertChain            As Long ' ptr -> CRYPT_PROVIDER_CERT
    dwSignerType            As Long
    psSigner                As Long ' ptr -> CMSG_SIGNER_INFO
    dwError                 As Long
    csCounterSigners        As Long
    pasCounterSigners       As Long ' ptr -> array of CRYPT_PROVIDER_SGNR
    pChainContext           As Long ' ptr -> CERT_CHAIN_CONTEXT
End Type

Private Type CRYPT_ATTRIBUTES
    cAttr                   As Long
    rgAttr                  As Long 'ptr -> CRYPT_ATTRIBUTE
End Type

Private Type CMSG_SIGNER_INFO
    dwVersion               As Long
    Issuer                  As CRYPTOAPI_BLOB ' CERT_NAME_BLOB
    SerialNumber            As CRYPTOAPI_BLOB ' CRYPT_INTEGER_BLOB
    HashAlgorithm           As CRYPT_ALGORITHM_IDENTIFIER
    HashEncryptionAlgorithm As CRYPT_ALGORITHM_IDENTIFIER
    EncryptedHash           As CRYPTOAPI_BLOB
    AuthAttrs               As CRYPT_ATTRIBUTES
    UnauthAttrs             As CRYPT_ATTRIBUTES
End Type

Private Type CRYPT_PROVIDER_DATA
    cbStruct                As Long
    pWintrustData           As Long ' ptr -> WINTRUST_DATA
    fOpenedFile             As Long ' BOOL
    hWndParent              As Long
    pgActionID              As Long
    hProv                   As Long ' HCRYPTPROV
    dwError                 As Long
    dwRegSecuritySettings   As Long
    dwRegPolicySettings     As Long
    psPfns                  As Long ' ptr -> CRYPT_PROVIDER_FUNCTIONS
    cdwTrustStepErrors      As Long
    padwTrustStepErrors     As Long ' ptr
    chStores                As Long
    pahStores               As Long ' ptr -> HCERTSTORE
    dwEncoding              As Long
    hMsg                    As Long ' HCRYPTMSG
    csSigners               As Long
    pasSigners              As Long ' ptr -> CRYPT_PROVIDER_SGNR
    csProvPrivData          As Long
    pasProvPrivData         As Long ' ptr -> array of CRYPT_PROVIDER_PRIVDATA structures
    dwSubjectChoice         As Long
    pPDSip                  As Long ' ptr -> PROVDATA_SIP
    pszUsageOID             As Long ' ptr -> char
    fRecallWithState        As Long ' BOOL
    sftSystemTime           As FILETIME
    pszCTLSignerUsageOID    As Long ' ptr -> char
    dwProvFlags             As Long
    dwFinalError            As Long
    pRequestUsage           As Long ' ptr -> CERT_USAGE_MATCH
    dwTrustPubSettings      As Long
    dwUIStateFlags          As Long
    pUnknown1               As Long 'undocumented (Win 7+)
    pUnknown2               As Long 'undocumented (Win 7+)
End Type

Private Type Data
    Enable  As Boolean
    lpFunc  As Long
    lpHook  As Long
    Prev    As Long
    old     As Currency
End Type

Private Declare Function CryptCATAdminAcquireContext Lib "Wintrust.dll" (hCatAdmin As Long, ByVal pgSubsystem As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptCATAdminAcquireContext2 Lib "Wintrust.dll" (hCatAdmin As Long, ByVal pgSubsystem As Long, ByVal pwszHashAlgorithm As Long, ByVal pStrongHashPolicy As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptCATAdminReleaseContext Lib "Wintrust.dll" (ByVal hCatAdmin As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptCATAdminCalcHashFromFileHandle Lib "Wintrust.dll" (ByVal hFile As Long, pcbHash As Long, pbHash As Byte, ByVal dwFlags As Long) As Long
Private Declare Function CryptCATAdminCalcHashFromFileHandle2 Lib "Wintrust.dll" (ByVal hCatAdmin As Long, ByVal hFile As Long, pcbHash As Long, pbHash As Byte, ByVal dwFlags As Long) As Long
Private Declare Function CryptCATAdminEnumCatalogFromHash Lib "Wintrust.dll" (ByVal hCatAdmin As Long, pbHash As Byte, ByVal cbHash As Long, ByVal dwFlags As Long, phPrevCatInfo As Long) As Long
Private Declare Function CryptCATCatalogInfoFromContext Lib "Wintrust.dll" (ByVal hCatInfo As Long, psCatInfo As CATALOG_INFO, ByVal dwFlags As Long) As Long
Private Declare Function CryptCATAdminReleaseCatalogContext Lib "Wintrust.dll" (ByVal hCatAdmin As Long, ByVal hCatInfo As Long, ByVal dwFlags As Long) As Long
Private Declare Function WinVerifyTrust Lib "Wintrust.dll" (ByVal hWnd As Long, pgActionID As GUID, ByVal pWVTData As Long) As Long
'Signer info extractor
Private Declare Function WTHelperProvDataFromStateData Lib "Wintrust.dll" (ByVal StateData As Long) As Long
Private Declare Function WTHelperGetProvSignerFromChain Lib "Wintrust.dll" (ByVal pProvData As Long, ByVal idxSigner As Long, ByVal fCounterSigner As Long, ByVal idxCounterSigner As Long) As Long
Private Declare Function CertDuplicateCertificateContext Lib "Crypt32.dll" (ByVal pCertContext As Long) As Long
Private Declare Function CertFreeCertificateContext Lib "Crypt32.dll" (ByVal pCertContext As Long) As Long
Private Declare Function CertNameToStr Lib "Crypt32.dll" Alias "CertNameToStrW" (ByVal dwCertEncodingType As Long, ByVal pName As Long, ByVal dwStrType As Long, ByVal psz As Long, ByVal csz As Long) As Long
Private Declare Function CertGetCertificateContextProperty Lib "Crypt32.dll" (ByVal pCertContext As Long, ByVal dwPropId As Long, pvData As Any, pcbData As Long) As Long
Private Declare Function CertGetNameString Lib "Crypt32.dll" Alias "CertGetNameStringW" (ByVal pCertContext As Long, ByVal dwType As Long, ByVal dwFlags As Long, pvTypePara As Any, ByVal pszNameString As Long, ByVal cchNameString As Long) As Long

'Private Declare Sub GetNativeSystemInfo Lib "kernel32.dll" (ByVal lpSystemInfo As Long)
Private Declare Function GetVersionEx Lib "kernel32.dll" Alias "GetVersionExW" (lpVersionInformation As Any) As Long
Private Declare Function FormatMessage Lib "kernel32.dll" Alias "FormatMessageW" (ByVal dwFlags As Long, ByVal lpSource As Long, ByVal dwMessageId As Long, ByVal dwLanguageId As Long, ByVal lpBuffer As Long, ByVal nSize As Long, Arguments As Any) As Long
Private Declare Function GetProcAddress Lib "kernel32.dll" (ByVal hModule As Long, ByVal lpProcName As String) As Long
Private Declare Function GetCurrentProcess Lib "kernel32.dll" () As Long
Private Declare Function IsWow64Process Lib "kernel32.dll" (ByVal hProcess As Long, ByRef Wow64Process As Long) As Long
Private Declare Function GetWindowsDirectory Lib "kernel32.dll" Alias "GetWindowsDirectoryW" (ByVal lpBuffer As Long, ByVal uSize As Long) As Long

Private Declare Function LoadLibrary Lib "kernel32.dll" Alias "LoadLibraryW" (ByVal lpFileName As Long) As Long
Private Declare Function FreeLibrary Lib "kernel32.dll" (ByVal hLibModule As Long) As Long
Private Declare Function CLSIDFromString Lib "ole32.dll" (ByVal lpszGuid As Long, pGuid As GUID) As Long

Private Declare Function CreateFile Lib "kernel32.dll" Alias "CreateFileW" (ByVal lpFileName As Long, ByVal dwDesiredAccess As Long, ByVal dwShareMode As Long, lpSecurityAttributes As Any, ByVal dwCreationDisposition As Long, ByVal dwFlagsAndAttributes As Long, ByVal hTemplateFile As Long) As Long
Private Declare Function CloseHandle Lib "kernel32.dll" (ByVal hObject As Long) As Long
Private Declare Function SetFilePointer Lib "kernel32.dll" (ByVal hFile As Long, ByVal lDistanceToMove As Long, lpDistanceToMoveHigh As Long, ByVal dwMoveMethod As Long) As Long
Private Declare Function ReadFile Lib "kernel32.dll" (ByVal hFile As Long, ByVal lpBuffer As Long, ByVal nNumberOfBytesToRead As Long, lpNumberOfByConstesRead As Long, ByVal lpOverlapped As Long) As Long
Private Declare Function GetFileAttributes Lib "kernel32.dll" Alias "GetFileAttributesW" (ByVal lpFileName As Long) As Long
Private Declare Function GetFileSizeEx Lib "kernel32.dll" (ByVal hFile As Long, lpFileSize As Any) As Long
'Private Declare Function Wow64DisableWow64FsRedirection Lib "kernel32.dll" (OldValue As Long) As Long
'Private Declare Function Wow64RevertWow64FsRedirection Lib "kernel32.dll" (ByVal OldValue As Long) As Long

Private Declare Function HeapFree Lib "kernel32.dll" (ByVal hHeap As Long, ByVal dwFlags As Long, ByVal lpMem As Long) As Long
Private Declare Function GetProcessHeap Lib "kernel32.dll" () As Long
Private Declare Function ArrPtr Lib "msvbvm60.dll" Alias "VarPtr" (arr() As Any) As Long
Private Declare Function memcpy Lib "kernel32.dll" Alias "RtlMoveMemory" (Destination As Any, Source As Any, ByVal length As Long) As Long
Private Declare Function GetMem4 Lib "msvbvm60.dll" (pSrc As Any, pDst As Any) As Long
Private Declare Function lstrlen Lib "kernel32.dll" Alias "lstrlenW" (ByVal lpString As Long) As Long
Private Declare Function lstrlenA Lib "kernel32.dll" (ByVal lpString As Long) As Long
Private Declare Function lstrcpyn Lib "kernel32.dll" Alias "lstrcpynW" (ByVal lpDst As Long, ByVal lpSrc As Long, ByVal iMaxLength As Long) As Long
Private Declare Function SysAllocStringByteLen Lib "oleaut32.dll" (ByVal pszStrPtr As Long, ByVal length As Long) As String
Private Declare Function FileTimeToSystemTime Lib "kernel32.dll" (lpFileTime As FILETIME, lpSystemTime As SYSTEMTIME) As Long
Private Declare Function FileTimeToLocalFileTime Lib "kernel32.dll" (lpFileTime As FILETIME, lpLocalFileTime As FILETIME) As Long
Private Declare Function SystemTimeToVariantTime Lib "oleaut32.dll" (lpSystemTime As SYSTEMTIME, vtime As Date) As Long
'API interceptor
'Private Declare Function LoadLibrary Lib "kernel32.dll" Alias "LoadLibraryW" (ByVal lpLibFileName As Long) As Long
'Private Declare Function GetProcAddress Lib "kernel32.dll" (ByVal hModule As Long, ByVal lpProcName As String) As Long
Private Declare Function VirtualProtect Lib "kernel32.dll" (lpAddress As Any, ByVal dwSize As Long, ByVal flNewProtect As Long, lpflOldProtect As Long) As Long
Private Declare Function GetMem8 Lib "msvbvm60.dll" (src As Any, dst As Any) As Long

Dim func()  As Data, Count   As Long

Private Const PAGE_EXECUTE_READWRITE As Long = &H40&

Private Const X509_ASN_ENCODING             As Long = 1&
Private Const PKCS_7_ASN_ENCODING           As Long = &H10000
Private Const CERT_X500_NAME_STR            As Long = 3&

Private Const CERT_HASH_PROP_ID             As Long = 3&
Private Const CERT_SIGNATURE_HASH_PROP_ID   As Long = 15&
Private Const CERT_SUBJECT_PUBLIC_KEY_MD5_HASH_PROP_ID As Long = 25&

Private Const CERT_NAME_ISSUER_FLAG         As Long = 1&
Private Const CERT_NAME_EMAIL_TYPE          As Long = 1& ' alternate Subject name (rfc822)
Private Const CERT_NAME_SIMPLE_DISPLAY_TYPE As Long = 4&
Private Const CERT_NAME_STR_ENABLE_PUNYCODE_FLAG As Long = &H200000 ' Punycode IA5String -> Unicode

Private Const WTD_UI_NONE                   As Long = 2&
' checking certificate revocation
Private Const WTD_REVOKE_NONE               As Long = 0&    ' do not check certificates for revocation
Private Const WTD_REVOKE_WHOLECHAIN         As Long = 1&    ' check for certificate revocation in all chain
' method of verification
Private Const WTD_CHOICE_FILE               As Long = 1&    ' check internal signature
Private Const WTD_CHOICE_CATALOG            As Long = 2&    ' check by certificate that is stored in local windows security storage
' flags
Private Const WTD_SAFER_FLAG                As Long = 256&   ' ??? (probably, no UI for XP SP2)
Private Const WTD_REVOCATION_CHECK_NONE     As Long = 16&    ' do not execute revecation checking of cert. chain
Private Const WTD_REVOCATION_CHECK_END_CERT As Long = &H20&  ' check for revocation end cert. only
Private Const WTD_REVOCATION_CHECK_CHAIN    As Long = &H40&  ' check all cert. chain ( require internet connection to port 53 TCP/UDP )
Private Const WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT As Long = &H80& ' check all chain, excepting the root cert.
Private Const WTD_NO_POLICY_USAGE_FLAG      As Long = 4&     ' do not mention on local security policy settings
Private Const WTD_CACHE_ONLY_URL_RETRIEVAL  As Long = 4096&  ' check for certificate revocation but only by local cache
Private Const WTD_LIFETIME_SIGNING_FLAG     As Long = &H800& ' check exparation date of certificate
' action
Private Const WTD_STATEACTION_IGNORE        As Long = 0&
Private Const WTD_STATEACTION_VERIFY        As Long = 1&
Private Const WTD_STATEACTION_CLOSE         As Long = 2&
' context
Private Const WTD_UICONTEXT_EXECUTE         As Long = 0&
' errors
Private Const TRUST_E_SUBJECT_NOT_TRUSTED   As Long = &H800B0004
Private Const TRUST_E_PROVIDER_UNKNOWN      As Long = &H800B0001
Private Const TRUST_E_ACTION_UNKNOWN        As Long = &H800B0002
Private Const TRUST_E_SUBJECT_FORM_UNKNOWN  As Long = &H800B0003
Private Const CERT_E_REVOKED                As Long = &H800B010C
Private Const CERT_E_EXPIRED                As Long = &H800B0101
Private Const TRUST_E_BAD_DIGEST            As Long = &H80096010
Private Const TRUST_E_NOSIGNATURE           As Long = &H800B0100
Private Const TRUST_E_EXPLICIT_DISTRUST     As Long = &H800B0111
Private Const CRYPT_E_SECURITY_SETTINGS     As Long = &H80092026
Private Const CERT_E_UNTRUSTEDROOT          As Long = &H800B0109
Private Const CERT_E_PURPOSE                As Long = &H800B0106
'OID
Private Const szOID_CERT_STRONG_SIGN_OS_1   As String = "1.3.6.1.4.1.311.72.1.1"
Private Const szOID_CERT_STRONG_KEY_OS_1    As String = "1.3.6.1.4.1.311.72.2.1"
'Crypt Algorithms
Private Const BCRYPT_SHA1_ALGORITHM         As String = "SHA1"      '160-bit
Private Const BCRYPT_SHA256_ALGORITHM       As String = "SHA256"    '256-bit
'Secondary signatures
Private Const WSS_VERIFY_SPECIFIC           As Long = 1&
Private Const WSS_GET_SECONDARY_SIG_COUNT   As Long = 2&
Private Const CERT_STRONG_SIGN_OID_INFO_CHOICE As Long = 2&
' other
Private Const INVALID_HANDLE_VALUE          As Long = -1&
Private Const ERROR_INSUFFICIENT_BUFFER     As Long = 122&
Private Const GENERIC_READ                  As Long = &H80000000
Private Const FILE_SHARE_READ               As Long = 1&
Private Const FILE_SHARE_WRITE              As Long = 2&
Private Const FILE_SHARE_DELETE             As Long = 4&
Private Const OPEN_EXISTING                 As Long = 3&
Private Const INVALID_SET_FILE_POINTER      As Long = &HFFFFFFFF
Private Const FILE_BEGIN                    As Long = 0&
Private Const NO_ERROR                      As Long = 0&

Private Const VER_NT_WORKSTATION            As Long = 1&

Dim WINTRUST_ACTION_GENERIC_VERIFY_V2   As GUID
Dim DRIVER_ACTION_VERIFY                As GUID


Public Sub WipeSignResult(SignResult As SignResult_TYPE)
    With SignResult     'clear results of checking
        .ReturnCode = TRUST_E_NOSIGNATURE
        .FullMessage = vbNullString
        .ShortMessage = "TRUST_E_NOSIGNATURE: Not signed"
        .Issuer = vbNullString
        .HashRootCert = vbNullString
        .HashFileCode = vbNullString
        .isSigned = False
        .isLegit = False
        .isSignedByCert = False
        .CatalogPath = vbNullString
        .isEmbedded = False
        .isSelfSigned = False
        .AlgorithmCertHash = vbNullString
        .AlgorithmSignDigest = vbNullString
        .Issuer = vbNullString
        .SubjectName = vbNullString
        .SubjectEmail = vbNullString
        .DateCertBegin = #12:00:00 AM#
        .DateCertExpired = #12:00:00 AM#
        .NumberOfSigns = 0
        .FilePathVerified = vbNullString
    End With
End Sub

Public Function SignVerify( _
    sFilePath As String, _
    ByVal flags As FLAGS_SignVerify, _
    SignResult As SignResult_TYPE) As Boolean
    
    On Error GoTo ErrorHandler
    
    AppendErrorLogCustom "SignVerify - Begin", "File: " & sFilePath
    
    ' in.  sFilePath - path to PE EXE file for validation
    ' in.  Flags - options for checking
    ' out. SignResult struct
    
    ' RETURN value - return true, if the integrity of the executable file is confirmed, notwithstanding:
    ' - possible restrictions in the local policy settings
    ' - self-signed certificate type (if the option 'CheckHoleChain = true' is not specified and revocation data are not cached)
    ' - checking for certificate exparation is not performed. If needed, add a flag WTD_LIFETIME_SIGNING_FLAG
    
    ' For even more strong verification (forbid reading revocation info from the cache),
    ' replace the flag WTD_CACHE_ONLY_URL_RETRIEVAL into WTD_REVOCATION_CHECK_NONE.
    ' Note that certificate revocation is a specific procedure and it should be performed
    ' only if you suspect that digital signature has been stolen or used in malware
    ' (this kind of verification require internet connection, can freeze a program and time-consuming).
    
    ' in. Flags (can be combined by 'OR' statement) - look at enum above to get description.
    
    Dim CatalogInfo         As CATALOG_INFO
    Dim WintrustData        As WINTRUST_DATA
    Dim WintrustCatalog     As WINTRUST_CATALOG_INFO
    Dim WintrustFile        As WINTRUST_FILE_INFO
    Dim CertSignPara        As CERT_STRONG_SIGN_PARA
    Dim SignSettings        As WINTRUST_SIGNATURE_SETTINGS
    Dim verInfo             As DRIVER_VER_INFO
    
    Static IsInit           As Boolean
    Static IsVistaAndNewer  As Boolean
    Static IsWin8AndNewer   As Boolean
    Static SignCache()      As SignResult_TYPE
    Static SC_pos           As Long
    #If UseHashTable Then
        Static oSignIndex As clsTrickHashTable
    #Else
        Static oSignIndex As Object
    #End If
    
    Dim i               As Long
    Dim hCatAdmin       As Long
    Dim hFile           As Long
    Dim FileSize        As Currency
    Dim HashSize        As Long
    Dim aFileHash()     As Byte
    Dim sBuf            As String
    Dim CatalogContext  As Long
    Dim sMemberTag      As String
    Dim ReturnFlag      As Boolean
    Dim ReturnVal       As Long
    Dim ActionGuid      As GUID
    Dim Success         As Boolean
    Dim RedirResult     As Boolean
    Dim bOldRedir       As Boolean
    
    WipeSignResult SignResult
    
    ToggleWow64FSRedirection True, , bOldRedir
    
    If (flags And SV_CheckSecondarySignature) Then flags = flags Or SV_CacheDoNotLoad Or SV_CacheDoNotSave Or SV_DisableCatalogVerify
    
    If 0 = ObjPtr(oSignIndex) Then                              'init. cache subsystem
        If Not CBool(flags And SV_CacheDoNotSave) Then
            #If UseHashTable Then
                Set oSignIndex = New clsTrickHashTable
            #Else
                Set oSignIndex = CreateObject("Scripting.Dictionary")
            #End If
            oSignIndex.CompareMode = vbTextCompare
            ReDim SignCache(100)
        End If
    ElseIf Not CBool(flags And SV_CacheDoNotLoad) Then
        If oSignIndex.Exists(sFilePath) Then
            SignResult = SignCache(oSignIndex(sFilePath))
            GoTo Finalize
        End If
    End If
    
    If Not CBool(flags And SV_CacheDoNotSave) Then
        SC_pos = SC_pos + 1
        If UBound(SignCache) < SC_pos Then ReDim Preserve SignCache(UBound(SignCache) + 100)
        If oSignIndex.Exists(sFilePath) Then
            oSignIndex(sFilePath) = SC_pos
        Else
            oSignIndex.Add sFilePath, SC_pos
        End If
    End If
    
    If Not IsInit Then                                          'Checking requirements
        IsInit = True
        
        Dim hLib As Long
        hLib = LoadLibrary(StrPtr("Wintrust.dll"))              'Redirector issues, if they are present, should be alerted here
        If hLib = 0 Then
            ErrorMsg Err, "SignVerify", "NOT SUPPORTED."
            SignResult.ShortMessage = "NOT SUPPORTED."
            GoTo Finalize
        Else
            FreeLibrary hLib: hLib = 0
        End If
        
        '// TODO: make revision:  inf(2) / 10 ' (!!!)
        
        Dim inf(68) As Long, MajorMinor As Single
        inf(0) = 276: GetVersionEx inf(0): MajorMinor = inf(1) + inf(2) / 10: IsVistaAndNewer = (MajorMinor >= 6): IsWin8AndNewer = (MajorMinor >= 6.2)
        
        CLSIDFromString StrPtr("{F750E6C3-38EE-11D1-85E5-00C04FC295EE}"), DRIVER_ACTION_VERIFY
        CLSIDFromString StrPtr("{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}"), WINTRUST_ACTION_GENERIC_VERIFY_V2
    End If
    
    If (flags And SV_isDriver) Then
        ActionGuid = DRIVER_ACTION_VERIFY
    Else
        ActionGuid = WINTRUST_ACTION_GENERIC_VERIFY_V2
    End If
    
    SignResult.FilePathVerified = sFilePath
    
    'If Not FileExists(sFilePath) Then GoTo Finalize
    
    'redir. OFF
    RedirResult = ToggleWow64FSRedirection(False, sFilePath)
    'opening the file
    hFile = CreateFile(StrPtr(sFilePath), GENERIC_READ, FILE_SHARE_READ Or FILE_SHARE_WRITE Or FILE_SHARE_DELETE, ByVal 0&, OPEN_EXISTING, ByVal 0&, ByVal 0&)
    
    If hFile = INVALID_HANDLE_VALUE Then GoTo Finalize
    'redir. ON
    If RedirResult Then ToggleWow64FSRedirection True
    
    CatalogInfo.cbStruct = Len(CatalogInfo)
    WintrustFile.cbStruct = Len(WintrustFile)
    
'    'alternate (by policy)
'    With CertSignPara
'        .cbSize = LenB(CertSignPara)
'        .dwInfoChoice = CERT_STRONG_SIGN_OID_INFO_CHOICE
'        'szOID_CERT_STRONG_SIGN_OS_1    'SHA2
'        'szOID_CERT_STRONG_KEY_OS_1     'SHA1 + SHA2
'        .pszOID = StrPtr(szOID_CERT_STRONG_KEY_OS_1)
'    End With
    
    If IsWin8AndNewer Then
        ' obtain context for procedure of signature verification
        
        'by policy
        'CryptCATAdminAcquireContext2 Context, VarPtr(DRIVER_ACTION_VERIFY), 0&, VarPtr(CertSignPara), 0&
        
        'sha1
        'CryptCATAdminAcquireContext2 Context, VarPtr(DRIVER_ACTION_VERIFY), StrPtr(BCRYPT_SHA1_ALGORITHM), 0&, 0&
        
        'sha256
        CryptCATAdminAcquireContext2 hCatAdmin, VarPtr(DRIVER_ACTION_VERIFY), StrPtr(BCRYPT_SHA256_ALGORITHM), 0&, 0&
        
        ' if future OS will not support sha256, you can pass 0, so system will choose lowest allowed algorithm:
        'CryptCATAdminAcquireContext2 hCatAdmin, VarPtr(DRIVER_ACTION_VERIFY), 0&, 0&, 0&
        
        
    End If
    
    If hCatAdmin = 0 Then
        If Not (CBool(CryptCATAdminAcquireContext(hCatAdmin, VarPtr(DRIVER_ACTION_VERIFY), 0&))) Then
        
            WriteError Err, SignResult, "CryptCATAdminAcquireContext"
            GoTo Finalize
        End If
    End If
    
    If (INVALID_HANDLE_VALUE = hFile) Then
        WriteError Err, SignResult, "CreateFile"
        GoTo Finalize
    End If
    
    FileSize = FileLenW(, hFile) ' file size == 0 ?
    
    If FileSize = 0@ Or (FileSize > MAX_FILE_SIZE And Not CBool(flags And SV_NoFileSizeLimit)) Then
        GoTo Finalize
    End If
    
    If IsWin8AndNewer Then
        ' obtain size needed for hash (Win8+)
        Success = CryptCATAdminCalcHashFromFileHandle2(hCatAdmin, hFile, HashSize, ByVal 0&, 0&)

        If Err.LastDllError = ERROR_INSUFFICIENT_BUFFER Then
            Success = False
            ReDim aFileHash(HashSize - 1&)
            If CBool(CryptCATAdminCalcHashFromFileHandle2(hCatAdmin, hFile, HashSize, aFileHash(0), 0&)) Then Success = True
        End If
    End If
    
    If (HashSize = 0& Or Not Success) Then
        ' obtain size needed for hash
        CryptCATAdminCalcHashFromFileHandle hFile, HashSize, ByVal 0&, 0&
    
        If (HashSize = 0&) Then
            WriteError Err, SignResult, "CryptCATAdminCalcHashFromFileHandle"
            GoTo Finalize
        End If

        ' allocating the memory
        ReDim aFileHash(HashSize - 1&)

        ' calculation of the hash
        If Not CBool(CryptCATAdminCalcHashFromFileHandle(hFile, HashSize, aFileHash(0), 0&)) Then
        
            WriteError Err, SignResult, "CryptCATAdminCalcHashFromFileHandle"
            GoTo Finalize
        End If
    End If
    
    ' Converting hash into string
    For i = 0& To UBound(aFileHash)
        sMemberTag = sMemberTag & Right$("0" & Hex$(aFileHash(i)), 2&)
    Next
    SignResult.HashFileCode = sMemberTag
    
    ' Search sec. catalogue by hash
    If Not HasCatRootVulnerability() Then 'avoid M$ bug with C:\WINDOWS\system32\catroot2\{GUID} file
    
        'Win8+: hCatAdmin should be obtained using DRIVER_ACTION_VERIFY provider
        CatalogContext = CryptCATAdminEnumCatalogFromHash(hCatAdmin, aFileHash(0), HashSize, 0&, ByVal 0&)
    End If
    
    '//TODO: add searching of any user-supplied catalogs
    'ActionGuid should be WINTRUST_ACTION_GENERIC_VERIFY_V2 in this case
    
    If (CatalogContext) Then
        If CryptCATCatalogInfoFromContext(CatalogContext, CatalogInfo, 0&) Then
        
            SignResult.CatalogPath = StringFromPtrW(VarPtr(CatalogInfo.wszCatalogFile(0)))
        Else
            WriteError Err, SignResult, "CryptCATCatalogInfoFromContext"
            CryptCATAdminReleaseCatalogContext hCatAdmin, CatalogContext, 0&
            CatalogContext = 0&
        End If
    End If
    
    ' preparing WINTRUST_DATA
    
    With WintrustData
        'fill in common values
        
        .cbStruct = Len(WintrustData)
        .dwUIChoice = WTD_UI_NONE
        .dwStateAction = WTD_STATEACTION_VERIFY
        
        If flags And SV_CheckRevocation Then
            .dwProvFlags = .dwProvFlags Or WTD_REVOCATION_CHECK_CHAIN
            .fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN
        Else
            ' obtain data about cert. chain revocation from local cache only, if they were saved ( >= Vista ). Do not use internet connection.
            .dwProvFlags = .dwProvFlags Or IIf(IsVistaAndNewer, WTD_CACHE_ONLY_URL_RETRIEVAL, WTD_REVOCATION_CHECK_NONE)
            .fdwRevocationChecks = WTD_REVOKE_NONE
        End If
        
        '.dwProvFlags = .dwProvFlags Or WTD_NO_POLICY_USAGE_FLAG                                          ' do not check certificate purpose (disabled)
        If flags And SV_AllowExpired Then .dwProvFlags = .dwProvFlags Or WTD_LIFETIME_SIGNING_FLAG        ' invalidate expired signatures
        .dwProvFlags = .dwProvFlags Or WTD_SAFER_FLAG                                                     ' without UI
    End With
    
    ' If we got a valid context, verify the signature through the catalog.
    ' Otherwise (if Embedded signature is exist or flag "Ignore checking by catalogue" is set), trying to verify internal signature of the file:
    
    If (CatalogContext = 0& Or (flags And SV_DisableCatalogVerify)) Then
        'embedded signature
    
        With WintrustData                               'WINTRUST_DATA
            .dwUnionChoice = WTD_CHOICE_FILE
            .pUnion = VarPtr(WintrustFile)     'pFile
            
            If (flags And SV_CheckSecondarySignature) Then .dwStateAction = WTD_STATEACTION_IGNORE ' hWVTStateData doesn't needed
        End With
    
        With WintrustFile                               'WINTRUST_FILE_INFO
            .cbStruct = Len(WintrustFile)
            .pcwszFilePath = StrPtr(sFilePath)
            .hFile = hFile
        End With
       
        If IsWin8AndNewer Then 'settings to get the number of signatures
    
            With SignSettings
                .cbStruct = LenB(SignSettings)
                .pCryptoPolicy = 0& 'VarPtr(CertSignPara); NULL - mean all policies.
                .dwFlags = WSS_GET_SECONDARY_SIG_COUNT
            End With
        
            WintrustData.pSignatureSettings = VarPtr(SignSettings)
        End If
        
    Else ' catalogue signature
        
        SignResult.isSigned = True
        SignResult.isSignedByCert = True
        
        'Disable OS version checking by passing in a DRIVER_VER_INFO structure.
        verInfo.cbStruct = LenB(verInfo)
        
        With WintrustData                               'WINTRUST_DATA
            .pPolicyCallbackData = VarPtr(verInfo)
            .dwUnionChoice = WTD_CHOICE_CATALOG
            .pUnion = VarPtr(WintrustCatalog)       'pCatalog
            .dwUIContext = WTD_UICONTEXT_EXECUTE
        End With
        
        ' Fill in catalogue structure
        With WintrustCatalog                            'WINTRUST_CATALOG_INFO
            .cbStruct = Len(WintrustCatalog)
            .dwCatalogVersion = 0&
            .pcwszCatalogFilePath = VarPtr(CatalogInfo.wszCatalogFile(0))
            .pcwszMemberTag = StrPtr(sMemberTag)
            .pcwszMemberFilePath = StrPtr(sFilePath)
            .hMemberFile = hFile
            .pbCalculatedFileHash = VarPtr(aFileHash(0))
            .cbCalculatedFileHash = HashSize
            .hCatAdmin = hCatAdmin
        End With
    End If
    
    RedirResult = ToggleWow64FSRedirection(False, sFilePath)
    
    ' calling main verification function
    ' INVALID_HANDLE_VALUE means non-interactive checking (without UI)
    ' WintrustData.hWVTStateData ' -> contains additional info about signature (if WTD_STATEACTION_VERIFY flag was set)
    
    ' Files properly signed by catalogue may (should be always?) verified under DRIVER_ACTION_VERIFY policy provider.
    ' Files signed by user-supplied catalogue (.cat files out of %SystemRoot%\System32\Catroot directory),
    '  should be verified under WINTRUST_ACTION_GENERIC_VERIFY_V2 policy provider (!).
    '  Example: "C:\Program Files\WindowsApps\king.com.CandyCrushSodaSaga_1.75.600.0_x86__kgqvnymyfvs32\AppxMetadata\CodeIntegrity.cat"
    '  => "C:\Program Files\WindowsApps\king.com.CandyCrushSodaSaga_1.75.600.0_x86__kgqvnymyfvs32\stritz.exe"
    
    ReturnVal = WinVerifyTrust(INVALID_HANDLE_VALUE, ActionGuid, VarPtr(WintrustData))
    
    If RedirResult Then ToggleWow64FSRedirection True
    
    If ReturnVal <> TRUST_E_NOSIGNATURE And _
        ReturnVal <> TRUST_E_BAD_DIGEST And _
        ReturnVal <> TRUST_E_PROVIDER_UNKNOWN _
        And Not SignResult.isSignedByCert Then
        
        SignResult.NumberOfSigns = SignSettings.cSecondarySigs + 1&
        
        'verify secondary signature
        
        If (flags And SV_CheckSecondarySignature) Then
            If SignResult.NumberOfSigns < 2 Or Not IsWin8AndNewer Then
                WipeSignResult SignResult
                ReturnVal = TRUST_E_NOSIGNATURE
            Else
                'free resources
                WintrustData.dwStateAction = WTD_STATEACTION_CLOSE
                WinVerifyTrust INVALID_HANDLE_VALUE, ActionGuid, VarPtr(WintrustData)
                
                'restarting context
                CryptCATAdminReleaseContext hCatAdmin, 0&
                CryptCATAdminAcquireContext2 hCatAdmin, VarPtr(DRIVER_ACTION_VERIFY), StrPtr(BCRYPT_SHA256_ALGORITHM), 0&, 0&
                
                WintrustData.dwStateAction = WTD_STATEACTION_VERIFY
                SignSettings.dwFlags = WSS_VERIFY_SPECIFIC
                
                SignSettings.dwIndex = IIf(SignSettings.dwVerifiedSigIndex = 0, 1, 0) 'checking another one index
                
                ReturnVal = WinVerifyTrust(INVALID_HANDLE_VALUE, ActionGuid, VarPtr(WintrustData))
            End If
        End If
    End If
    
    'calling signer info extractor routine
    
    If ReturnVal <> TRUST_E_NOSIGNATURE And _
        ReturnVal <> TRUST_E_BAD_DIGEST And _
        ReturnVal <> TRUST_E_PROVIDER_UNKNOWN Then
    
        GetSignerInfo WintrustData.hWVTStateData, SignResult
    End If
    
    ' correcting result if SV_AllowSelfSigned specified to allow self-signed certificate
    If ReturnVal = 0 Then
        ReturnFlag = True
    ElseIf (flags And SV_AllowSelfSigned) And (ReturnVal = CERT_E_UNTRUSTEDROOT) Then
        ReturnFlag = True
    ElseIf (flags And SV_AllowExpired) And (ReturnVal = CERT_E_EXPIRED) Then
        ReturnFlag = True
    End If
    
    With SignResult
        
        .isSigned = True
        
        Select Case ReturnVal
        Case 0
            .ShortMessage = "Legit signature."
        Case TRUST_E_SUBJECT_NOT_TRUSTED
            .ShortMessage = "TRUST_E_SUBJECT_NOT_TRUSTED"
            'The user clicked "No" when asked to install and run.
        Case TRUST_E_PROVIDER_UNKNOWN
            .ShortMessage = "TRUST_E_PROVIDER_UNKNOWN"
            'The trust provider is not recognized on this system.
        Case TRUST_E_ACTION_UNKNOWN
            .ShortMessage = "TRUST_E_ACTION_UNKNOWN"
            'The trust provider does not support the specified action.
        Case TRUST_E_SUBJECT_FORM_UNKNOWN
            .ShortMessage = "TRUST_E_SUBJECT_FORM_UNKNOWN"
            'This can happen when WinVerifyTrust is called on an unknown file type
        Case CERT_E_REVOKED
            .ShortMessage = "CERT_E_REVOKED"
            'A certificate was explicitly revoked by its issuer.
        Case CERT_E_EXPIRED
            .ShortMessage = "CERT_E_EXPIRED"
            'A required certificate is not within its validity period when verifying against the current system clock or the timestamp in the signed file
        Case CERT_E_PURPOSE
            .ShortMessage = "CERT_E_PURPOSE"
            'The certificate is being used for a purpose other than one specified by the issuing CA.
        Case TRUST_E_BAD_DIGEST
            .ShortMessage = "TRUST_E_BAD_DIGEST"
            'This will happen if the file has been modified or corruped.
        Case TRUST_E_NOSIGNATURE
            .isSigned = False
            If TRUST_E_NOSIGNATURE = Err.LastDllError Or _
                TRUST_E_SUBJECT_FORM_UNKNOWN = Err.LastDllError Or _
                TRUST_E_PROVIDER_UNKNOWN = Err.LastDllError Or _
                Err.LastDllError = 0 Then
                .ShortMessage = "TRUST_E_NOSIGNATURE: Not signed"
            Else
                .ShortMessage = "TRUST_E_NOSIGNATURE: Not valid signature"
                'The signature was not valid or there was an error opening the file.
            End If
        Case TRUST_E_EXPLICIT_DISTRUST
            .ShortMessage = "TRUST_E_EXPLICIT_DISTRUST: Signature is forbidden"
            'The signature Is present, but specifically disallowed
            'The hash that represents the subject or the publisher is not allowed by the admin or user.
        Case CRYPT_E_SECURITY_SETTINGS
            .ShortMessage = "CRYPT_E_SECURITY_SETTINGS"
            ' The hash that represents the subject or the publisher was not explicitly trusted by the admin and the
            ' admin policy has disabled user trust. No signature, publisher or time stamp errors.
        Case CERT_E_UNTRUSTEDROOT
            .isSelfSigned = True
            .ShortMessage = "CERT_E_UNTRUSTEDROOT: Verified, but self-signed"
            'A certificate chain processed, but terminated in a root certificate which is not trusted by the trust provider.
        Case Else
            .ShortMessage = "Other error. Code = " & ReturnVal & ". LastDLLError = " & Err.LastDllError
            'The UI was disabled in dwUIChoice or the admin policy has disabled user trust. ReturnVal contains the publisher or time stamp chain error.
        End Select
    
        ' Other error codes can be found on MSDN:
        ' https://msdn.microsoft.com/en-us/library/windows/desktop/aa377188%28v=vs.85%29.aspx?f=255&MSPPError=-2147217396
        ' https://msdn.microsoft.com/en-us/library/ee488436.aspx
        ' This is not an exhaustive list.
    
        .FullMessage = ErrMessageText(ReturnVal)
        .ReturnCode = ReturnVal
        .isLegit = ReturnFlag
        SignVerify = .isLegit
        
        If .isSignedByCert Then
            If (flags And SV_CheckEmbeddedPresence) Then .isEmbedded = IsSignPresent(hFile)
        Else
            If .isSigned Then .isEmbedded = True
        End If
        
    End With
    
    ' Release sec. cat. context
    If (CatalogContext) Then
        CryptCATAdminReleaseCatalogContext hCatAdmin, CatalogContext, 0&
    End If
    
    ' Free memory used by provider
    WintrustData.dwStateAction = WTD_STATEACTION_CLOSE
    WinVerifyTrust INVALID_HANDLE_VALUE, ActionGuid, VarPtr(WintrustData)
    
    If verInfo.pcSignerCertContext Then
        CertFreeCertificateContext verInfo.pcSignerCertContext
    End If
    
Finalize:
    If Not CBool(flags And SV_CacheDoNotSave) Then SignCache(SC_pos) = SignResult
    
    ' closing the file, release admin. cat. context
    If hCatAdmin <> 0 Then
        CryptCATAdminReleaseContext hCatAdmin, 0&
    End If
    If hFile <> 0 Then
        CloseHandle hFile
    End If
    ToggleWow64FSRedirection bOldRedir
    
    AppendErrorLogCustom "SignVerify - End", "Legit? " & SignResult.isLegit
    
    Exit Function
ErrorHandler:
    ErrorMsg Err, "SignVerify", sFilePath
    ToggleWow64FSRedirection bOldRedir
    If inIDE Then Stop: Resume Next
End Function

Private Function HasCatRootVulnerability() As Boolean
    On Error GoTo ErrHandler
    Static IsInit       As Boolean
    Static VulnStatus   As Boolean
    
    If IsInit Then
        HasCatRootVulnerability = VulnStatus
        Exit Function
    Else
        IsInit = True
    End If
    
    Dim inf(68) As Long: inf(0) = 276: GetVersionEx inf(0): If inf(1) < 6 Then Exit Function 'XP is not vulnerable
    
    Dim sFile   As String
    Dim lr      As Long
    Dim WinDir  As String
    
    WinDir = GetWindowsDir()
    sFile = DirW$(WinDir & "\System32\catroot2\*") 'not affected by wow64
    Do While Len(sFile)
        If sFile Like "{????????????????????????????????????}" Then
            lr = GetFileAttributes(StrPtr(WinDir & "\System32\catroot2\" & sFile))
            If lr <> INVALID_HANDLE_VALUE And (lr And vbDirectory) Then
                VulnStatus = True: HasCatRootVulnerability = True: Exit Function
            End If
        End If
        sFile = DirW$()
    Loop
    Exit Function
ErrHandler:
    ErrorMsg Err, "HasCatRootVulnerability"
    If inIDE Then Stop: Resume Next
End Function

'
' ================ Signer info extractor ==================
'

Private Sub GetSignerInfo(StateData As Long, SignResult As SignResult_TYPE)
    On Error GoTo ErrorHandler
    
    AppendErrorLogCustom "GetSignerInfo - Begin"
    
    Dim NumberOfSignatures As Long
    Dim CertInfo As CERT_INFO
    Dim pCertificate As Long
    Dim i As Long
    Dim J As Long
    Dim Signature() As SIGNATURE_TYPE
    Dim idxRoot As Long
    Dim idxSigner As Long
    Dim CPSigner() As CRYPT_PROVIDER_SGNR
    Dim MsgSigner As CMSG_SIGNER_INFO
    Dim AlgoDesc As String
    
    'CERT_HASH_PROP_ID              'Certificate & Signature hashes
    'CERT_SHA1_HASH_PROP_ID
    'CERT_SIGNATURE_HASH_PROP_ID
    
    'For simplicity, we'll get properties only for 1-st and last certificate in the trust chain
    'CPCERT(0): it's a final cert. in chain - we'll get timestamp and name of actual Subject / email from there
    'CPCERT(CPSigner.csCertChain - 1): it's a root cert. - we'll get hash from there to compare
    '  with well known trusted Certification Authorities (this module contains the list of Microsoft hashes of root certs.)
    
    If GetSignaturesFromStateData(StateData, Signature, CPSigner) Then
      With SignResult
        If Signature(0).cCert > 0 Then
            'to equire properties from all certificates
            'For i = 0 To ubound(Signature)
            '    For j = 0 To Signature(i).cCert - 1
            '        Signature(i).Certificate(j) 'e.t.c.
            '    Next
            'Next
            
            'Root cert. index (Issuer)
            idxRoot = UBound(Signature(0).Certificate)
            pCertificate = Signature(0).Certificate(idxRoot)
            
            .HashRootCert = ExtractPropertyFromCertificateByID(pCertificate, CERT_HASH_PROP_ID)
            
            'Cert. index of person who sign (Subject)
            idxSigner = 0
            pCertificate = Signature(0).Certificate(idxSigner)
            
            If GetCertInfoFromCertificate(pCertificate, CertInfo) Then
                
                ' alternate method
                '.Issuer = GetCertString(pCertificate, CERT_NAME_SIMPLE_DISPLAY_TYPE, CERT_NAME_ISSUER_FLAG)
                .Issuer = GetSignerNameFromBLOB(CertInfo.Issuer)
                .SubjectName = GetSignerNameFromBLOB(CertInfo.Subject)
                .SubjectEmail = ExtractStringFromCertificate(pCertificate, CERT_NAME_EMAIL_TYPE, CERT_NAME_STR_ENABLE_PUNYCODE_FLAG)
                
                .DateCertBegin = FileTime_To_VT_Date(CertInfo.NotBefore)
                .DateCertExpired = FileTime_To_VT_Date(CertInfo.NotAfter)
                
            End If
            
            ' Get hash algorithm of signature
            memcpy MsgSigner, ByVal CPSigner(0).psSigner, LenB(MsgSigner)
            
            .AlgorithmSignDigest = StringFromPtrA(MsgSigner.HashAlgorithm.pszObjId)
            
            AlgoDesc = GetHashNameByOID(.AlgorithmSignDigest)
            If Len(AlgoDesc) <> 0 Then .AlgorithmSignDigest = .AlgorithmSignDigest & " " & "(" & AlgoDesc & ")"
            
            ' Get hash algorithm of certificate
            If GetCertInfoFromCertificate(pCertificate, CertInfo) Then
                .AlgorithmCertHash = StringFromPtrA(CertInfo.SignatureAlgorithm.pszObjId)
            End If
            
            AlgoDesc = GetHashNameByOID(.AlgorithmCertHash)
            If Len(AlgoDesc) <> 0 Then .AlgorithmCertHash = .AlgorithmCertHash & " " & "(" & AlgoDesc & ")"
            
            'release
            For i = 0 To UBound(Signature)
                For J = 0 To UBound(Signature(i).Certificate)
                    CertFreeCertificateContext Signature(i).Certificate(J)
                Next
            Next
        End If
      End With
    End If
    
    AppendErrorLogCustom "GetSignerInfo - End"
    
    Exit Sub
ErrorHandler:
    ErrorMsg Err, "GetSignerInfo"
    If inIDE Then Stop: Resume Next
End Sub

Private Function GetHashNameByOID(sOID As String) As String
    On Error GoTo ErrorHandler
    Dim AlgoDesc As String
    
    Select Case sOID ' for exhaustive list look at: https://msdn.microsoft.com/en-us/library/windows/desktop/aa381133(v=vs.85).aspx
            
        Case "1.2.840.113549.2.5":      AlgoDesc = "MD5 RSA"            ' szOID_RSA_MD5
        Case "1.2.840.113549.1.1.4":    AlgoDesc = "MD5 RSA"            ' szOID_RSA_MD5RSA
        Case "1.2.840.113549.1.1.5":    AlgoDesc = "SHA-1 RSA"          ' szOID_RSA_SHA1RSA
        Case "1.2.840.113549.1.1.11":   AlgoDesc = "SHA-256 RSA"        ' szOID_RSA_SHA256RSA
        Case "1.2.840.113549.1.1.12":   AlgoDesc = "SHA-384 RSA"        ' szOID_RSA_SHA384RSA
        Case "1.2.840.113549.1.1.13":   AlgoDesc = "SHA-512 RSA"        ' szOID_RSA_SHA512RSA
                
        Case "1.2.840.10045.4.1":       AlgoDesc = "SHA-1 ECDSA"        ' szOID_ECDSA_SHA1
        Case "1.2.840.10045.4.3.2":     AlgoDesc = "SHA-256 ECDSA"      ' szOID_ECDSA_SHA256
        Case "1.2.840.10045.4.3.3":     AlgoDesc = "SHA-384 ECDSA"      ' szOID_ECDSA_SHA384
        Case "1.2.840.10045.4.3.4":     AlgoDesc = "SHA-512 ECDSA"      ' szOID_ECDSA_SHA512
                
        Case "1.2.840.10040.4.3":       AlgoDesc = "SHA-1 DSA"          ' szOID_X957_SHA1DSA
        
        Case "1.3.14.3.2.3":            AlgoDesc = "MD5 OIWSEC"         ' szOID_OIWSEC_md5RSA
        Case "1.3.14.3.2.25":           AlgoDesc = "MD5 OIWSEC"         ' szOID_OIWSEC_md5RSASign
        Case "1.3.14.3.2.26":           AlgoDesc = "SHA-1 OIWSEC"       ' szOID_OIWSEC_sha1
        Case "1.3.14.3.2.27":           AlgoDesc = "SHA-1 OIWSEC_DSA"   ' szOID_OIWSEC_dsaSHA1
        Case "1.3.14.3.2.28":           AlgoDesc = "SHA-1 OIWSEC_DSA"   ' szOID_OIWSEC_dsaCommSHA1
        Case "1.3.14.3.2.29":           AlgoDesc = "SHA-1 OIWSEC_RSA"   ' szOID_OIWSEC_sha1RSASign
                
        Case "2.16.840.1.101.3.4.2.1":  AlgoDesc = "SHA-256 NIST"       ' szOID_NIST_sha256
        Case "2.16.840.1.101.3.4.2.2":  AlgoDesc = "SHA-384 NIST"       ' szOID_NIST_sha384
        Case "2.16.840.1.101.3.4.2.3":  AlgoDesc = "SHA-512 NIST"       ' szOID_NIST_sha512
        
        Case Else:                      AlgoDesc = vbNullString
    End Select
            
    GetHashNameByOID = AlgoDesc
    Exit Function
ErrorHandler:
    ErrorMsg Err, "GetHashNameByOID", "OID:", sOID
    If inIDE Then Stop: Resume Next
End Function

Private Function GetSignaturesFromStateData(StateData As Long, Signature() As SIGNATURE_TYPE, CPSigner() As CRYPT_PROVIDER_SGNR) As Long
    'Signature(x).Certificate() returns array of pointers to CERT_CONTEXT
    On Error GoTo ErrorHandler

    Dim pProvData   As Long
    'Dim ProvData    As CRYPT_PROVIDER_DATA
    Dim pCPSigner   As Long
    Dim CPCERT()    As CRYPT_PROVIDER_CERT
    Dim lpOldPt     As Long
    Dim lpSA        As Long
    Dim idxSign     As Long
    Dim i           As Long
    Dim cbCrypProvCert As Long
    
    pProvData = WTHelperProvDataFromStateData(StateData)
    
    If 0 = pProvData Then Exit Function
    
    'Test reason: not needed
    'GetMem4 ByVal pProvData, ProvData.cbStruct
    'memcpy ProvData, ByVal pProvData, IIf(ProvData.cbStruct < LenB(ProvData), ProvData.cbStruct, LenB(ProvData))    'Win7+ size of struct > &H80
    
    idxSign = 0
    Do
    
        pCPSigner = WTHelperGetProvSignerFromChain(pProvData, idxSign, 0&, 0&)
        
        If 0 <> pCPSigner Then
            
            ReDim Preserve CPSigner(idxSign)
            
            memcpy CPSigner(idxSign), ByVal pCPSigner, LenB(CPSigner(0))
            
            ' number of CRYPT_PROVIDER_CERT structures
            If 0 <> CPSigner(idxSign).csCertChain And 0 <> CPSigner(idxSign).pasCertChain Then
                
                'CPSigner.pasCertChain: contains certificates of all chain. Last index is a root cert
                
                ReDim Preserve Signature(0 To idxSign)
                ReDim Signature(idxSign).Certificate(0 To CPSigner(idxSign).csCertChain - 1)
                Signature(idxSign).cCert = CPSigner(idxSign).csCertChain
                
                'Iterating all certificates in the chain
                
                ReDim CPCERT(CPSigner(idxSign).csCertChain - 1)

'                GetMem4 ByVal ArrPtr(CPCERT()), lpSA
'                GetMem4 ByVal lpSA + 12, lpOldPt
'                GetMem4 CPSigner(idxSign).pasCertChain, ByVal lpSA + 12

                'Added support for Windows 2000 (sizeof(CRYPT_PROVIDER_CERT) < 60)
                GetMem4 ByVal CPSigner(idxSign).pasCertChain, cbCrypProvCert
                
                For i = 0 To CPSigner(idxSign).csCertChain - 1
                    memcpy CPCERT(i), ByVal CPSigner(idxSign).pasCertChain + cbCrypProvCert * i, IIf(cbCrypProvCert <= LenB(CPCERT(0)), cbCrypProvCert, LenB(CPCERT(0)))
                Next
                
                For i = 0 To CPSigner(idxSign).csCertChain - 1
                    Signature(idxSign).Certificate(i) = CertDuplicateCertificateContext(CPCERT(i).pCert)
                Next
                
'                GetMem4 lpOldPt, ByVal lpSA + 12
                
                'if you need CounterSigners, use this:
                'If CPSigner.csCounterSigners <> 0 Then
                '    'WTHelperGetProvCertFromChain with CPSigner.pasCounterSigners
                '    'GetCertificateDescription, e.t.c.
                'End If
                'https://www.idrix.fr/Root/Samples/VerifyExeSignature.cpp
            End If
            
            idxSign = idxSign + 1
            GetSignaturesFromStateData = idxSign
            
        End If
    Loop While pCPSigner
    
    'WINTRUST_Free ProvData.padwTrustStepErrors
    'WINTRUST_Free ProvData.pPDSip
    'WINTRUST_Free ProvData.psPfns
    'WINTRUST_Free pProvData
    Exit Function
ErrorHandler:
    ErrorMsg Err, "GetSignaturesFromStateData"
    If inIDE Then Stop: Resume Next
End Function

Private Function WINTRUST_Free(ptr As Long) As Long
    If 0 <> ptr Then HeapFree GetProcessHeap(), 0, ptr
End Function

Private Function GetCertInfoFromCertificate(pCertificate As Long, out_CertInfo As CERT_INFO) As Boolean  'ptr -> CERT_CONTEXT
    On Error GoTo ErrorHandler
    
    Dim Certificate As CERT_CONTEXT
    Dim pCertInfo   As Long
    
    If 0 <> pCertificate Then
        memcpy Certificate, ByVal pCertificate, LenB(Certificate)
        pCertInfo = Certificate.pCertInfo

        If 0 <> pCertInfo Then
            memcpy out_CertInfo, ByVal pCertInfo, LenB(out_CertInfo)
            GetCertInfoFromCertificate = True
        End If
    End If
    Exit Function
ErrorHandler:
    ErrorMsg Err, "GetCertInfoFromCertificate"
    If inIDE Then Stop: Resume Next
End Function

Private Function GetSignerNameFromBLOB(Crypto_BLOB As CRYPTOAPI_BLOB) As String
    On Error GoTo ErrorHandler
    
    Dim sName As String
    Dim pos   As Long
    
    sName = GetCertNameString(Crypto_BLOB) ' X.509 string
    
    pos = InStr(sName, "CN=")
    If pos <> 0 Then
        sName = Mid$(sName, pos + 3)
        If Left$(sName, 1) = """" Then 'inside quotes?
            pos = InStr(2, sName, """")
            If pos <> 0 Then
                sName = Mid$(sName, 2, Len(sName) - 2)
            Else
                sName = Mid$(sName, 2)
            End If
        Else
            pos = InStr(sName, ", ")
            If pos <> 0 Then sName = Left$(sName, pos - 1)
        End If
    End If
    
    GetSignerNameFromBLOB = sName
    
    ' RFC2253 - http://www.ietf.org/rfc/rfc2253.txt
    '
    ' CN  = commonName
    ' L   = localityName
    ' ST  = stateOrProvinceName
    ' O   = organizationName
    ' OU  = organizationalUnitName
    ' C   = countryName
    ' STREET = streetAddress
    ' DC  = domainComponent
    ' UID = userid

    'Example: C=RU, PostalCode=115093, S=Moscow, L=Moscow, STREET="Street Serpukhovsko B, 44", O=RIVER SOLUTIONS, CN=RIVER SOLUTIONS

    Exit Function
ErrorHandler:
    ErrorMsg Err, "GetSignerNameFromBLOB"
    If inIDE Then Stop: Resume Next
End Function

Private Function GetCertNameString(Blob As CRYPTOAPI_BLOB) As String
    On Error GoTo ErrorHandler

    Dim BufferSize As Long
    Dim sName As String
    
    BufferSize = CertNameToStr(X509_ASN_ENCODING, VarPtr(Blob), CERT_X500_NAME_STR, 0&, 0&)

    If BufferSize Then
        sName = String$(BufferSize, vbNullChar)
        CertNameToStr X509_ASN_ENCODING Or PKCS_7_ASN_ENCODING, VarPtr(Blob), CERT_X500_NAME_STR, StrPtr(sName), BufferSize
        sName = Left$(sName, lstrlen(StrPtr(sName)))
    End If
    
    GetCertNameString = sName
    Exit Function
ErrorHandler:
    ErrorMsg Err, "GetCertNameString"
    If inIDE Then Stop: Resume Next
End Function

Private Function ExtractStringFromCertificate(pCertContext As Long, dwType As Long, Optional dwFlags As Long) As String
    On Error GoTo ErrorHandler

    Dim bufSize As Long
    Dim sName As String

    bufSize = CertGetNameString(pCertContext, dwType, dwFlags, 0&, 0&, 0&)
    
    If bufSize Then
        sName = String$(bufSize, vbNullChar)
        CertGetNameString pCertContext, dwType, dwFlags, 0&, StrPtr(sName), bufSize
        sName = Left$(sName, lstrlen(StrPtr(sName)))
    End If
    
    ExtractStringFromCertificate = sName
    Exit Function
ErrorHandler:
    ErrorMsg Err, "ExtractStringFromCertificate"
    If inIDE Then Stop: Resume Next
End Function

Private Function ExtractPropertyFromCertificateByID(pCertContext As Long, ID As Long) As String
    On Error GoTo ErrorHandler

    Dim bufSize As Long
    Dim buf()   As Byte
    Dim i       As Long
    Dim hash    As String

    CertGetCertificateContextProperty pCertContext, ID, 0&, bufSize
    If bufSize Then
        ReDim buf(bufSize - 1)
        hash = String$(bufSize * 2, 0&)
        If CertGetCertificateContextProperty(pCertContext, ID, buf(0), bufSize) Then
            For i = 0 To bufSize - 1
                Mid$(hash, i * 2 + 1) = Right$("0" & Hex$(buf(i)), 2&)
            Next
        End If
    End If
    
    ExtractPropertyFromCertificateByID = hash
    
    Exit Function
ErrorHandler:
    ErrorMsg Err, "ExtractPropertyFromCertificate"
    If inIDE Then Stop: Resume Next
End Function

Public Function IsMicrosoftCertHash(hash As String) As Boolean
    Static IsInit As Boolean
    Static Hashes(9) As String
    Dim i As Long
    
    If Not IsInit Then
        IsInit = True
        'Microsoft Root Certificate Authority;CDD4EEAE6000AC7F40C3802C171E30148030C072;391BE92883D52509155BFEAE27B9BD340170B76B;983B132635B7E91DEEF54A6780C09269
        Hashes(0) = "CDD4EEAE6000AC7F40C3802C171E30148030C072"
        'Microsoft Root Authority;A43489159A520F0D93D032CCAF37E7FE20A8B419;8B3C3087B7056F5EC5DDBA91A1B901F0;3FC8CB0BC05241E58D65E9448B2D07C2
        Hashes(1) = "A43489159A520F0D93D032CCAF37E7FE20A8B419"
        'Microsoft Root Certificate Authority 2011;8F43288AD272F3103B6FB1428485EA3014C0BCFE;279CD652C4E252BFBE5217AC722205D7729BA409148CFA9E6D9E5B1CB94EAFF1;BB048F1838395F6FC3A1F3D2B7E97654
        Hashes(2) = "8F43288AD272F3103B6FB1428485EA3014C0BCFE"
        'Microsoft Authenticode(tm) Root Authority;7F88CD7223F3C813818C994614A89C99FA3B5247;D67576F5521D1CCAB52E9215E0F9F743;07D34DED498D4577F261BD38B6B8736E
        Hashes(3) = "7F88CD7223F3C813818C994614A89C99FA3B5247"
        'Microsoft Root Certificate Authority 2010;3B1EFD3A66EA28B16697394703A72CA340A05BD5;08FBA831C08544208F5208686B991CA1B2CFC510E7301784DDF1EB5BF0393239;3C70FAEA25600CE3B2CC5F0B222ED629
        Hashes(4) = "3B1EFD3A66EA28B16697394703A72CA340A05BD5"
        'Copyright (c) 1997 Microsoft Corp.;245C97DF7514E7CF2DF8BE72AE957B9E04741E85;9DF0D13100123AECA770130F4AD8D209;7FDFF50729446710244A447CA2A197EA
        Hashes(5) = "245C97DF7514E7CF2DF8BE72AE957B9E04741E85"
        'Microsoft Digital Media Authority 2005;15693E85E02E411116FB8D7FD97205EEE09150A6
        Hashes(6) = "15693E85E02E411116FB8D7FD97205EEE09150A6"
        'Microsoft Digital Media Authority 2005;6AF4C632A97856E54597922BF67CB179E93D2553
        Hashes(7) = "6AF4C632A97856E54597922BF67CB179E93D2553"
        'Microsoft Testing Root Certificate Authority 2010;98725873611882C17A9D478FDC46F9C172552D63
        Hashes(8) = "98725873611882C17A9D478FDC46F9C172552D63"
        'Microsoft Development PCA 2014;98725873611882C17A9D478FDC46F9C172552D63
        Hashes(9) = "98725873611882C17A9D478FDC46F9C172552D63"
    End If
    
    For i = 0 To UBound(Hashes)
        If StrComp(hash, Hashes(i), vbTextCompare) = 0 Then IsMicrosoftCertHash = True: Exit For
    Next
End Function

Public Function IsMicrosoftFile(sFile As String) As Boolean
    Dim SignResult As SignResult_TYPE
    SignVerify sFile, 0&, SignResult
    If SignResult.isLegit Then
        IsMicrosoftFile = IsMicrosoftCertHash(SignResult.HashRootCert)
    End If
End Function
    
Public Function IsSignPresent(Optional hFile As Long, Optional sFilePath As String) As Boolean
    On Error GoTo ErrorHandler:
    ' 3Ch -> PE_Header offset
    ' PE_Header offset + 18h = Optional_PE_Header
    ' PE_Header offset + 78h (x86) or + 88h (x64) = Data_Directories offset
    ' Data_Directories offset + 20h = SecurityDir -> Address (dword), Size (dword) for digital signature.
    
    Const IMAGE_FILE_MACHINE_I386   As Integer = &H14C
    Const IMAGE_FILE_MACHINE_IA64   As Integer = &H200
    Const IMAGE_FILE_MACHINE_AMD64  As Integer = &H8664
    
    Dim PE_offset       As Long
    Dim SignAddress     As Long
    Dim DataDir_offset  As Long
    Dim DirSecur_offset As Long
    Dim Machine         As Integer
    Dim FSize           As Currency
    Dim RedirResult     As Boolean
    
    If 0 = hFile Then
        If 0 <> Len(sFilePath) Then
            RedirResult = ToggleWow64FSRedirection(False, sFilePath)
            hFile = CreateFile(StrPtr(sFilePath), GENERIC_READ, FILE_SHARE_READ Or FILE_SHARE_WRITE Or FILE_SHARE_DELETE, ByVal 0&, OPEN_EXISTING, ByVal 0&, ByVal 0&)
            If RedirResult Then ToggleWow64FSRedirection True
        End If
        If hFile <= 0 Then Exit Function
    End If
    
    FSize = FileLenW(, hFile)
    
    If FSize >= &H3C& + 6& Then
        GetW hFile, &H3C& + 1&, PE_offset
        GetW hFile, PE_offset + 4& + 1&, Machine
        
        Select Case Machine
            Case IMAGE_FILE_MACHINE_I386
                DataDir_offset = PE_offset + &H78&
            Case IMAGE_FILE_MACHINE_AMD64, IMAGE_FILE_MACHINE_IA64
                DataDir_offset = PE_offset + &H88&
            Case Else
                ErrorMsg Err, "IsSignPresent", "Unknown architecture, not PE EXE or damaged image.", "File:", sFilePath
        End Select
        If 0 <> DataDir_offset Then
            DirSecur_offset = DataDir_offset + &H20&
            If FSize >= DirSecur_offset + 4& Then GetW hFile, DirSecur_offset + 1&, SignAddress
        End If
    End If
    
    IsSignPresent = (SignAddress <> 0)
    If 0 <> Len(sFilePath) Then CloseHandle hFile
    Exit Function
ErrorHandler:
    ErrorMsg Err, "IsSignPresent", "File:", sFilePath
    If 0 <> Len(sFilePath) And 0 <> hFile Then CloseHandle hFile
    If inIDE Then Stop: Resume Next
End Function

'
' ============= Helper functions ===============
'

Private Function GetWindowsDir() As String
    Static SysRoot As String
    Static IsInit As Boolean
    Dim lr As Long
    Dim osi As OSVERSIONINFOEX
    
    If IsInit Then
        GetWindowsDir = SysRoot
        Exit Function
    End If
    
    IsInit = True
    GetVersionEx osi
    
    If osi.wProductType = VER_NT_WORKSTATION Then
        SysRoot = String$(MAX_PATH, 0&)
        lr = GetWindowsDirectory(StrPtr(SysRoot), MAX_PATH)
        If lr Then
            SysRoot = Left$(SysRoot, lr)
        Else
            SysRoot = Environ$("SystemRoot")
        End If
    Else
        SysRoot = Environ$("SystemRoot") 'avoid path virtualization on Windows Server with Terminal Services
    End If
    GetWindowsDir = SysRoot
End Function

Private Function IsWow64() As Boolean
    Dim hModule As Long, procAddr As Long, lIsWin64 As Long
    Static IsInit As Boolean, Result As Boolean

    If IsInit Then
        IsWow64 = Result
    Else
        IsInit = True
        hModule = LoadLibrary(StrPtr("kernel32.dll"))
        If hModule Then
            procAddr = GetProcAddress(hModule, "IsWow64Process")
            If procAddr <> 0 Then
                IsWow64Process GetCurrentProcess(), lIsWin64
                Result = CBool(lIsWin64)
                IsWow64 = Result
            End If
            FreeLibrary hModule
        End If
    End If
End Function

Function IsWin64() As Boolean   ' OS bittness (not supported in Win2k)
'    Const PROCESSOR_ARCHITECTURE_AMD64 As Long = 9&
'    Dim si(35) As Byte
'    GetNativeSystemInfo VarPtr(si(0))
'    If si(0) And PROCESSOR_ARCHITECTURE_AMD64 Then IsWin64 = True
    IsWin64 = IsWow64()
End Function

Private Function FileTime_To_VT_Date(ftime As FILETIME) As Date
    Dim DateTime As Date
    Dim stime As SYSTEMTIME
    FileTimeToLocalFileTime ftime, ftime            ' consider time zone
    FileTimeToSystemTime ftime, stime               ' FILETIME -> SYSTEMTIME
    SystemTimeToVariantTime stime, DateTime         ' SYSTEMTIME -> Date
    FileTime_To_VT_Date = DateTime
End Function

Private Function StringFromPtrA(ByVal ptr As Long) As String
    If 0& <> ptr Then
        StringFromPtrA = SysAllocStringByteLen(ptr, lstrlenA(ptr))
    End If
End Function

Private Function StringFromPtrW(ByVal ptr As Long) As String
    Dim strSize As Long
    If 0 <> ptr Then
        strSize = lstrlen(ptr)
        If 0 <> strSize Then
            StringFromPtrW = String$(strSize, 0&)
            lstrcpyn StrPtr(StringFromPtrW), ptr, strSize + 1&
        End If
    End If
End Function

' Proxy-wrapper for ErrorMsg
Private Sub WriteError(ByVal ErrObj As ErrObject, SignResult As SignResult_TYPE, FunctionName As String)
    
    Dim SaveError As ErrObject
    Set SaveError = ErrObj
    
    If &H800700C1 = ErrObj.LastDllError Then
        ' if we got "%1 is not a valid Win32 application." and PE EXE contain pointer to SecurityDir struct,
        ' it's mean digital signature was damaged
        ' https://chentiangemalc.wordpress.com/2014/08/01/case-of-the-server-returned-a-referral/
        
        If IsSignPresent(, SignResult.FilePathVerified) Then
            'SignResult.ShortMessage = "Digital signature is present, but damaged (probably, file is patched)." ' overwrite
            
            'ErrReport = ErrReport & vbCrLf & "Digital signature is present, but damaged (probably, file is patched)." & ": " & SignResult.FilePathVerified
            ErrReport = ErrReport & vbCrLf & Translate(1866) & ": " & SignResult.FilePathVerified & GetFileMD5(SignResult.FilePathVerified)
            Exit Sub
        End If
    End If
    
    ErrorMsg SaveError, FunctionName, SignResult.ShortMessage, "File: ", SignResult.FilePathVerified
End Sub

'Public Function inIDE() As Boolean
'    inIDE = (App.LogMode = 0)
'End Function


' ---------------------------------------------------------------------------------------------------
' StartupList2 routine
' ---------------------------------------------------------------------------------------------------

Public Function VerifyFileSignature(sFile$) As Integer
'    If Not FileExists(App.Path & "\istrusted.dll") Then
'        If msgboxw("To verify file signatures, StartupList needs to " & _
'                  "download an external library from www.merijn.org. " & _
'                  vbCrLf & vbCrLf & "Continue?", vbYesNo + vbQuestion) = vbYes Then
'            If DownloadFile("http://www.merijn.org/files/istrusted.dll", App.Path & "\istrusted.dll") Then
'                'file downloaded ok, continue
'            Else
'                'file download failed
'                bAbort = True
'                VerifyFileSignature = -1
'                Exit Function
'            End If
'        Else
'            'user aborted download
'            bAbort = True
'            VerifyFileSignature = -1
'            Exit Function
'        End If
'    End If
    
    If WinVerifyFile(sFile) Then
        VerifyFileSignature = 1
    Else
        VerifyFileSignature = 0
    End If
End Function

Public Sub WinTrustVerifyChildNodes(sKey$)
    If bAbort Then Exit Sub
    If Not NodeExists(sKey) Then Exit Sub
    Dim nodFirst As Node, nodCurr As Node
    Set nodFirst = frmStartupList2.tvwMain.Nodes(sKey).Child
    Set nodCurr = nodFirst
    If Not (nodCurr Is Nothing) Then
        Do
            If nodCurr.Children > 0 Then WinTrustVerifyChildNodes nodCurr.Key
        
            WinTrustVerifyNode nodCurr.Key
        
            If nodCurr = nodFirst.LastSibling Then Exit Do
            Set nodCurr = nodCurr.Next
            If bAbort Then Exit Sub
        Loop
    End If
End Sub

Public Sub WinTrustVerifyNode(sKey$)
    If bAbort Then Exit Sub
    If Not NodeIsValidFile(frmStartupList2.tvwMain.Nodes(sKey)) Then Exit Sub
        
    Dim sFile$, sMD5$, sIcon$
    sFile = frmStartupList2.tvwMain.Nodes(sKey).Text
    If Not FileExists(sFile) Then
        sFile = frmStartupList2.tvwMain.Nodes(sKey).Tag
        If Not FileExists(sFile) Then Exit Sub
    End If
    'Verifying file signature of:
    Status Translate(973) & " " & sFile
    'sMD5 = GetFileMD5(sFile)
    
    Select Case VerifyFileSignature(sFile)
        Case 1: sIcon = "wintrust1"
        Case 0: sIcon = "wintrust3"
        Case -1: Exit Sub
    End Select
    
    frmStartupList2.tvwMain.Nodes(sKey).Image = sIcon
    frmStartupList2.tvwMain.Nodes(sKey).SelectedImage = sIcon
End Sub

Private Function WinVerifyFile(sFile As String) As Boolean
    Dim SignResult As SignResult_TYPE
    SignVerify sFile, 0&, SignResult
    WinVerifyFile = SignResult.isLegit
End Function
