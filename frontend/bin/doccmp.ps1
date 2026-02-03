param(
    [Parameter(Mandatory=$true)]
    [string]$OriginalPath,

    [Parameter(Mandatory=$true)]
    [string]$RevisedPath,

    [Parameter(Mandatory=$true)]
    [string]$PdfPath,

    [switch]$IsDocx
)

# Constants
$wdCompareDestinationNew = 2
$wdFormatPDF = 17
$wdFormatDocumentDefault = 16
$wdDoNotSaveChanges = 0

# Create Word Application
$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0

try {
    # Resolve absolute paths
    $OriginalPath = (Resolve-Path $OriginalPath).Path
    $RevisedPath = (Resolve-Path $RevisedPath).Path
    $PdfPath = [System.IO.Path]::GetFullPath($PdfPath)

    Write-Host "Opening original document: $OriginalPath"
    if (!(Test-Path $OriginalPath)) { throw "Original file not found: $OriginalPath" }
    
    # Try to unblock the file (in case of Mark of the Web)
    Unblock-File -Path $OriginalPath -ErrorAction SilentlyContinue
    
    $origSize = (Get-Item $OriginalPath).Length
    Write-Host "Original file size: $origSize bytes"
    if ($origSize -eq 0) { throw "Original file is empty" }

    # Open(FileName, ConfirmConversions, ReadOnly, AddToRecentFiles, ...)
    # Open as ReadOnly ($true) to prevent "File in Use" dialogs or locking issues
    $doc = $word.Documents.Open($OriginalPath, $false, $true)

    Write-Host "Comparing with revised document: $RevisedPath"
    if (!(Test-Path $RevisedPath)) { throw "Revised file not found: $RevisedPath" }
    
    Unblock-File -Path $RevisedPath -ErrorAction SilentlyContinue
    
    $revSize = (Get-Item $RevisedPath).Length
    Write-Host "Revised file size: $revSize bytes"
    if ($revSize -eq 0) { throw "Revised file is empty" }
    # Compare(Name, AuthorName, CompareTarget, DetectFormatChanges, IgnoreAllComparisonWarnings, AddToRecentFiles, RemovePersonalInformation, RemoveDateAndTime)
    $doc.Compare($RevisedPath, "System", $wdCompareDestinationNew, $true, $true, $false, $false, $false)

    # The comparison result is the active document
    $diffDoc = $word.ActiveDocument
    
    if ($IsDocx) {
        Write-Host "Saving comparison to DOCX: $PdfPath"
        $diffDoc.SaveAs2($PdfPath, $wdFormatDocumentDefault)
    } else {
        Write-Host "Saving comparison to PDF: $PdfPath"
        $diffDoc.SaveAs2($PdfPath, $wdFormatPDF)
    }
    
    $diffDoc.Close($wdDoNotSaveChanges)
    # The original doc is still open, close it too
    $doc.Close($wdDoNotSaveChanges)
    
    Write-Host "Success!"
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}
finally {
    $word.Quit()
    # Cleanup COM objects
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null
    Remove-Variable word
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
