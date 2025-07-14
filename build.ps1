$ErrorActionPreference = "Stop"
function ConvertTo-Hashtable {
    [CmdletBinding()]
    [OutputType('hashtable')]
    param (
        [Parameter(ValueFromPipeline)]
        $InputObject
    )
    process {
        ## Return null if the input is null. This can happen when calling the function
        ## recursively and a property is null
        if ($null -eq $InputObject) {
            return $null
        }
        ## Check if the input is an array or collection. If so, we also need to convert
        ## those types into hash tables as well. This function will convert all child
        ## objects into hash tables (if applicable)
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $collection = @(
                foreach ($object in $InputObject) {
                    ConvertTo-Hashtable -InputObject $object
                }
            )
            ## Return the array but don't enumerate it because the object may be pretty complex
            Write-Output -NoEnumerate $collection
        }
        elseif ($InputObject -is [psobject]) {
            ## If the object has properties that need enumeration
            ## Convert it to its own hash table and return it
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
            }
            $hash
        }
        else {
            ## If the object isn't an array, collection, or other object, it's already a hash table
            ## So just return it.
            $InputObject
        }
    }
}

# Main script begins
if ( Test-Path .\build\bin ) { Remove-Item .\build\bin -Recurse -Force }
if ( Test-Path .\build\nupkg ) { Remove-Item .\build\nupkg -Recurse -Force }
New-Item -Path ".\build\nupkg" -ItemType "directory" -Force
New-Item -Path ".\build\bin" -ItemType "directory" -Force

Write-Output "[INFO] Gathering manifests..."

# Get list of manifest files
$files = $(Get-ChildItem -Path ".\${env:BASE_IMAGE}" -Recurse -File -Include *manifest.json*);

# Translate manifest file content into K,V hashtables
$content = @();
For ($i = 0; $i -lt $files.Count; $i++) {
    $content += $($files[$i] | Get-Content -Raw | ConvertFrom-Json | ConvertTo-Hashtable);
}
$packages = @{};
For ($i = 0; $i -lt $content.Count; $i++) {
    # Keys are part of the hashtable and cannot be referenced by index.
    # So we convert them to a list of strings and iterate through that.
    $keys = $content[$i].Keys -as [string[]];
    For ($n = 0; $n -lt $keys.Count; $n++) {
        $value = $content[$i].$($keys[$n]);
        # Compare values for each key and drop lowest
        If (!$packages.ContainsKey($keys[$n])) {
            $packages.Add($keys[$n], $value);
        }
        ElseIf ($packages.$($keys[$n]).version -lt $value.version) {
            $packages.$($keys[$n]) = $value;
        }
        ElseIf (($packages.$($keys[$n]).version -eq $value.version) -and (($packages.$($keys[$n]).build -lt $value.build -and $packages.$($keys[$n]).build -ne 'latest') -or $value.build -eq 'latest')) {
            $packages.$($keys[$n]) = $value;            
        }
    }
}
# Convert K,V pairs back to JSON so we can log it to a file
$packages | ConvertTo-Json | Out-File -FilePath './manifest.json' -NoNewline -Force;

Write-Output "[INFO] Fetching NuGet Packages..."
$package_version = ""
$package_build = ""
# Iterate through packages
$keys = $packages.Keys -as [string[]];
For ($i = 0; $i -lt $keys.Count; $i++) {
    # Skip the package version record
    $name = $packages.$($keys[$i]).name
    if($name -eq "PACKAGE") { 
        $package_version = $packages[$keys[$i]].version
        $package_build = $packages[$keys[$i]].build
        Write-Output "package version $($package_version)"
        continue
    }
