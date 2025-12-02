param(
    [Parameter(Mandatory=$true)]
    [string]$InputPath,

    [Parameter(Mandatory=$true)]
    [string]$OutputPath
)

# Constants
$wdFormatPDF = 17
$wdDoNotSaveChanges = 0

# Create Word Application
$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0

try {
    # Resolve absolute paths
    $InputPath = (Resolve-Path $InputPath).Path
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

    Write-Host "Opening document: $InputPath"
    # Open(FileName, ConfirmConversions, ReadOnly, AddToRecentFiles, ...)
    $doc = $word.Documents.Open($InputPath, $false, $true)

    Write-Host "Saving to PDF: $OutputPath"
    $doc.SaveAs2($OutputPath, $wdFormatPDF)
    
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
