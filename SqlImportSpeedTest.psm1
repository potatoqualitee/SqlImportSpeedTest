#Requires -Version 3
Function Test-SqlImportSpeed {
<#
.SYNOPSIS
Demonstrates high performance inserts using PowerShell, Runspaces, and SqlBulkCopy. The secret sauce are batched dataset imports and runspaces within the StreamReader.

.DESCRIPTION
This script is intended to demonstrate the efficiency of really cool programming technique (though iDataReader may make it cooler). It also proves PowerShell's performance capabilities.

There are four datasets to choose from: customers data from the Chinook sample database, long/lat data from geonames.org, a really small two column (int, varchar(10)) table, all with one million rows. The fourth dataset is a large customer dataset with 25 million rows.

Each of the datasets are realistic. The geonames dataset has 19 columns including one varchar(max) and customers dataset has 12, all with varied and accurate datatypes.

If the csv files do not reside in the expected location (My Documents), they'll be automatically downloaded. 

By default, Test-SqlImportSpeed creates a database called pssqlbulkcopy, then imports one customer dataset to a table called speedtest.

When ran against SQL Server 2014 or greater, it can support memory optimized tables. The actual execution doesn't have a lot of error handling (like SqlBulkCopy itself) because that slows stuff down.  The blog post will explain how to troubleshoot.

Warning: This script leaves behind the CSV files it downloads, and the database it creates.

THIS CODE IS PROVIDED "AS IS", WITH NO WARRANTIES.

.PARAMETER SqlServer
Required. You must have db creator rights. By default, Windows Authentication is used.

.PARAMETER SqlCredential
Optional. Use SQL Server login instead of Windows Authentication.

.PARAMETER Database
Optional. You can change the database name, but you'll be prompted to confirm unless you use -Force or -Append. This is because the script drops and recreates the specified database with
bulk optimized options.

The table name will always be speedtest if you'd like to see the resulting data.

.PARAMETER Table
Optional. Table name in db.

.PARAMETER Dataset
Optional. This script tests against one of four CSV datasets. 

1. Default: 		CSV: 143 MB		Table: 222 MB		Million-row, 10-column Customer data from the Chinook sample database with data generated by RedGate Data Generator. 
2. Geonames: 		CSV: 122 MB 	Table: 175 MB 		Million-row, 19-column longitudes and latitudes data from geonames.org Includes varchar(max) which slows down import.
3. SuperSmall: 		CSV: 13.5 MB	Table: 27 MB		Million-row, 2 column (int and a varchar(10)). This one can import over 25 million rows a minute.
4. VeryLarge:		CSV: 3.6 GB		Table: 5566 MB		25 million-row, 10-column Customer data from the Chinook sample database with data generated by RedGate Data Generator.

The VeryLarge dataset requires 6GB of free disk space on the SQL Server and 4G on the client peforming the test. A one-time download of a 1.5 GB file is required.

.PARAMETER BatchSize
Optional. Default batchsize is 2000. That's what worked fastest for me.

.PARAMETER MinRunspaces
Optional. Minium Runspaces. Default is 1.

.PARAMETER MaxRunspaces
Optional. Maximum Runspace throttle. Default is 5.

.PARAMETER MemoryOptimized
Optional. Only works on SQL Server 2014 and above. This smokes - I've gotten 184,239 rows a second with this setting. Uses the Customer dataset. 

.PARAMETER NoDbDrop
Optional. Don't drop/recreate database.

.PARAMETER Append
Optional. Don't drop/recreate table.

.PARAMETER UseVarcharMax
Optional. Shows impact of using varchar(MAX)

.PARAMETER NoLockEscalation
Optional. Disable LockEscalation on table

.PARAMETER Threading
Optional. Apartment State for Runspaces. MTA for multithreaded and STA for single-threaded

.PARAMETER ShowErrors
Optional. Shows errors returned from the bulkinsert.

.PARAMETER EnableStreaming
Optional. Enables Streaming on SqlBulkCopy object. Doesn't usually have a positive impact.
		
.PARAMETER NoThreadReuse
Optional. By default, this module wil set $Host.Runspace.ThreadOptions = "ReuseThread" which has given around a 10% increase in speed. To see what happens when threads aren't reused, specify -NoThreadReuse.
	
	
.PARAMETER Force
Optional. If you use the -Database parameter, it'll warn you that the database will be dropped and recreated, then prompt to confirm. If you use -Force, there will be no prompt.


.NOTES 
Author  : Chrissy LeMaire (@cl), netnerds.net
Requires:     PowerShell Version 3.0, db creator privs on destination SQL Server
DateUpdated: 2016-6-5
Version: 0.7.3

.EXAMPLE   
Test-SqlImportSpeed -SqlServer sqlserver2014a

Drops pssqlbulkcopy database and recreates it, then adds a table called speedtest. Imports a million row dataset filled with longitude and latitude data. If CSV file does not exist, it will be downloaded to Documents\geonames.csv

.EXAMPLE   
Test-SqlImportSpeed -SqlServer sqlserver -Database TestDb -NoDbDrop -Table SuperSmall -Dataset SuperSmall

Does not drop and recreate destination database "TestDb" because -NoDbDrop was specified. Creates new table called SuperSmall and imports a million row, 2 column dataset.  If CSV file does not exist, it will be downloaded to Documents\supersmall.csv

.EXAMPLE   
Test-SqlImportSpeed -SqlServer sqlserver2014a -Dataset Customers -Append

Skips recreation of database and table. Imports a million row dataset filled with classic customer data. If CSV file does not exist, it will be downloaded to Documents\customers.csv

.EXAMPLE   
$cred = Get-Credential
Test-SqlImport -SqlServer sqlserver2014a -SqlCredential $cred -MinRunspaces 5 -MaxRunspaces 10 -BatchSize 50000

This allows you to login using SQL auth, and sets the MinRunspaces to 5 and the MaxRunspaces to 10. Sets the batchsize to 50000 rows.

#>
[CmdletBinding()] 
param(
	[parameter(Mandatory = $true)]
	[object]$SqlServer,
	[object]$SqlCredential,
	[ValidateSet("Customers","Geonames","SuperSmall","VeryLarge")] 
	[string]$Dataset ="Customers",
	[string]$Database = "pssqlbulkcopy",
	[string]$Table = "speedtest",
	[int]$BatchSize = 2000,
	[int]$MinRunspaces = 1,
	[int]$MaxRunspaces = 5,
	[switch]$MemoryOptimized,
	[switch]$NoDbDrop,
	[switch]$Append,
	[switch]$VarcharMax,
	[switch]$NoLockEscalation,
	[ValidateSet("Multi","Single")] 
	[string]$Threading="Multi",
	[switch]$ShowErrors,
	[switch]$EnableStreaming,
	[switch]$NoThreadReuse,
	[switch]$Force
)

BEGIN {
	
	Function Get-SqlDefaultPath {
		$sql = "select SERVERPROPERTY('InstanceDefaultDataPath') as physical_name"
		$cmd.CommandText = $sql
		$filepath = $cmd.ExecuteScalar()
		
		if ($filepath.length -lt 2) {
			$sql = "SELECT physical_name FROM model.sys.database_files where physical_name like '%.mdf'"
			$cmd.CommandText = $sql
			$filepath = $cmd.ExecuteScalar()
			$filepath = Split-Path $filepath
		}
		
		$filepath = $filepath.TrimEnd("\")
		return $filepath
	}
	
	Function Get-SqlVersion {
		$sql = "SELECT SERVERPROPERTY('productversion') as version"
		$cmd.CommandText = $sql
		$sqlversion = $cmd.ExecuteScalar()
		$sqlversion = ([version]$sqlversion).Major
		return $sqlversion 
	}
	
	Function Invoke-GarbageCollection {
		1..3 | foreach { [System.GC]::Collect() }
	}
	
	Function Get-SqlPacketSize {
		$sql = "EXEC sp_configure 'show advanced option', '1'
				RECONFIGURE
				CREATE TABLE #packetsize (name varchar(25),minimum int,maximum int,config int,run int)
				INSERT INTO #packetsize	EXEC sp_configure 'network packet size'
				SELECT run from  #packetsize"
		$cmd.CommandText = $sql
		try { $packetsize = $cmd.ExecuteScalar() } catch { $packetsize = 4096 }
		return $packetsize 
	}

	Function Restore-TestDb {
		if ($memoryOptimized -eq $true) {
			$defaultpath = Get-SqlDefaultPath  $conn
			$mosql = "ALTER DATABASE [$database] ADD FILEGROUP [memoptimized] CONTAINS MEMORY_OPTIMIZED_DATA
			ALTER DATABASE [pssqlbulkcopy] ADD FILE ( NAME = N'pssqlbulkcopy_mo', FILENAME = N'$defaultpath\$database_mo.ndf' ) TO FILEGROUP [memoptimized]
			ALTER DATABASE [$database] SET MEMORY_OPTIMIZED_ELEVATE_TO_SNAPSHOT ON"
		}
	
		if ($dataset -eq "verylarge") { $dbsize = "6GB" } else { $dbsize = "1GB" }
		$sql = "IF  EXISTS (SELECT name FROM master.dbo.sysdatabases WHERE name = N'$database')
				BEGIN
					ALTER DATABASE [$database] SET  SINGLE_USER WITH ROLLBACK IMMEDIATE
					DROP DATABASE [$database]
				END
				CREATE DATABASE  [$database]
				ALTER DATABASE [$database] MODIFY FILE ( NAME = N'$database', SIZE = $dbsize )
				ALTER DATABASE [$database] MODIFY FILE ( NAME = N'$($database)_log', SIZE = 10MB )
				ALTER DATABASE [$database] SET RECOVERY SIMPLE WITH NO_WAIT
				ALTER DATABASE [$database] SET PAGE_VERIFY NONE
				ALTER DATABASE [$database] SET AUTO_UPDATE_STATISTICS OFF
				ALTER DATABASE [$database] SET AUTO_CREATE_STATISTICS OFF
				ALTER DATABASE [$database] SET AUTO_CLOSE OFF
				ALTER DATABASE [$database] SET AUTO_SHRINK OFF
				$mosql
"
		Write-Verbose $sql
		$cmd.CommandText = $sql
		try {
			$cmd.ExecuteNonQuery() > $null
		} catch {
			throw $_.Exception.Message.ToString()
		}
	}
	
	Function New-Table {
		$conn.ChangeDatabase($database)
		if ($nolockescalation) { $le = "`nALTER TABLE $table SET (LOCK_ESCALATION = DISABLE)" }
		switch ($dataset) {
			"supersmall" {
							if ($memoryOptimized -eq $true) {
								$sql = "CREATE TABLE[dbo].[$table](id int INDEX ix_cid NONCLUSTERED NOT NULL, data varchar(10))"
							} else {
								$sql = "CREATE TABLE[dbo].[$table](id int, data varchar(10))"
							}
			}
			{ "customers" -or "verylarge"} {
							if ($memoryOptimized -eq $true) {
								$customerid = "[CustomerId] int INDEX ix_cid NONCLUSTERED NOT NULL,"
								$with = "WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_ONLY)"
							} else {
								$customerid = "[CustomerId] int,"
							}
							
							$sql = "CREATE TABLE[dbo].[$table](
							$customerid
							[FirstName] [nvarchar](40),
							[LastName] [nvarchar](20),
							[Company] [nvarchar](80),
							[Address] [nvarchar](70),
							[City] [nvarchar](40),
							[State] [varchar](40),
							[Country] [varchar](40),
							[PostalCode] [varchar](10),
							[Phone] [varchar](24),
							[Fax] [varchar](24),
							[Email] [varchar](60)
						) $with"
						}
			"geonames" {
					$sql = "CREATE TABLE [dbo].[$table](
							[GeoNameId] [int],
							[Name] [nvarchar](200),
							[AsciiName] [nvarchar](200),
							[AlternateNames] [nvarchar](max),
							[Latitude] [float],
							[Longitude] [float],
							[FeatureClass] [char](1),
							[FeatureCode] [varchar](10),
							[CountryCode] [char](2),
							[Cc2] [varchar](255),
							[Admin1Code] [varchar](20),
							[Admin2Code] [varchar](80),
							[Admin3Code] [varchar](20),
							[Admin4Code] [varchar](20),
							[Population] [bigint],
							[Elevation] [varchar](255),
							[Dem] [int],
							[Timezone] [varchar](40),
							[ModificationDate] [smalldatetime]
					    )"
			}
			
		}
		
		$sql += $le
		
		if ($varcharmax -eq $true) {
		$sql = "CREATE TABLE[dbo].[$table](
							$customerid
							[FirstName] [nvarchar](MAX),
							[LastName] [nvarchar](MAX),
							[Company] [nvarchar](MAX),
							[Address] [nvarchar](MAX),
							[City] [nvarchar](MAX),
							[State] [varchar](MAX),
							[Country] [varchar](MAX),
							[PostalCode] [varchar](MAX),
							[Phone] [varchar](MAX),
							[Fax] [varchar](MAX),
							[Email] [varchar](MAX)
						) $with"
		
		}
		
		Write-Verbose $sql
		$cmd.CommandText = $sql

		try { 
			Write-Output "Creating table $table"
			$cmd.ExecuteNonQuery() > $null
		} catch {
			Write-Output "Table may already exist. Use -Append to append."
			throw $_.Exception.Message.ToString()
		}
	}
	
	Function Get-Rowcount {
		$conn.ChangeDatabase($database)
		$sql = "SELECT COUNT(*) from $table"

		Write-Verbose $sql
		$cmd.CommandText = $sql

		try 
		{ 
			$rows = $cmd.ExecuteScalar()
		} catch {
			Write-Output "Couldn't get rowcount."
			throw $_.Exception.Message.ToString()
		}
		
		return $rows
	}
	
	Function Clear-DbCache {
		$cmd.CommandText = "SELECT IS_SRVROLEMEMBER ('sysadmin')"
		$sysadmin = $cmd.ExecuteScalar()
		
		if ($sysadmin -eq $true) {
			Write-Output "Clearing cache"
			$conn.ChangeDatabase($database)
			$sql = "CHECKPOINT; DBCC DROPCLEANBUFFERS"
			Write-Verbose $sql
			$cmd.CommandText = $sql
			
			try { $cmd.ExecuteNonQuery() > $null} 
			catch { throw $_.Exception.Message.ToString() }
		}
	}
}

PROCESS {
	
	if ($append -eq $true) { $nodbdrop = $true }
		
	
	switch ($threading) {
		"Multi" { $apartmentstate = "MTA" }
		"Single" { $apartmentstate = "STA" }
	}
	
	# Show warning if db name is not pssqlbulkcopy and -Force was not specified
	if ($database -ne "pssqlbulkcopy" -and ($force -eq $false -or $append -eq $false)) {
		$message = "This script will drop the database '$database' and recreate it."
		$question = "Are you sure you want to continue? (Use -Force to prevent this prompt)"
		$choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
		$choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
		$choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))
		
		$decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
		if ($decision -eq 1) { return }
	}

	# Create Connection String
	if ($SqlCredential.count -eq 0) {
			$connectionString = "Data Source=$sqlserver;Integrated Security=True;Connection Timeout=3;Initial Catalog=master"
	} else {
			$username = ($SqlCredential.UserName).TrimStart("\")
			$connectionString = "Data Source=$sqlserver;User Id=$($username); Password=$($SqlCredential.GetNetworkCredential().Password);Connection Timeout=3;Initial Catalog=master"
	}
	
	# Build the SQL Server Connection
	try {
		$conn = New-Object System.Data.SqlClient.SqlConnection
		$conn.ConnectionString = $connectionString
		$conn.Open()
	} catch {
		$message = $_.Exception.Message.ToString()
		Write-Verbose $message
		if ($message -match "A network") { $message = "Can't connect to $sqlserver." }
		elseif ($message -match "Login failed for user") { $message = "Login failed for $username." }
		throw $message
	}
	
	# Build the SQL Server Command
	$cmd = New-Object System.Data.SqlClient.SqlCommand
	$cmd.Connection = $conn
	
	# If -MemoryOptimized is specified, ensure the SQL Server supports it.
	if ($memoryOptimized -eq $true) {
		if ($dataset -eq "geonames") { throw "In-Memory testing can only be performed with the Customers dataset"}
		$sqlversion = Get-SqlVersion $conn
		if ($sqlversion -lt 12) { throw "In-Memory OLTP is only supported in SQL Server 2014 and above" }
		$bulkoptions = "Default"
	} else { $bulkoptions = "TableLock" }
	
	if ($nolockescalation -eq $true -and $sqlversion -lt 10) { throw "You can only disable lock escalation in SQL Server 2008 and above." }
		
	# Set dataset info
	if ($dataset -eq "geonames") {
		$csvfile = "$([Environment]::GetFolderPath('MyDocuments'))\geonames.csv"
		$onedriveurl = "https://www.dropbox.com/s/ans3gj9um88b1ko/Geonames.zip?dl=0&raw=1"
	} elseif ($dataset -eq "supersmall") {
		$csvfile = "$([Environment]::GetFolderPath('MyDocuments'))\supersmall.csv"
		$onedriveurl = "https://www.dropbox.com/s/on351ou8cr7l1ug/supersmall.zip?dl=0&raw=1"
	} elseif ($dataset -eq "verylarge") {
		$csvfile = "$([Environment]::GetFolderPath('MyDocuments'))\verylarge.csv"
		$onedriveurl = "http://1drv.ms/1OA9iZw"
	} else {
		$csvfile = "$([Environment]::GetFolderPath('MyDocuments'))\customers.csv"
		$onedriveurl = "https://www.dropbox.com/s/9yo11kqix1tu4te/customers.zip?dl=0&raw=1"
	}
	
	# Check for CSV
	if ((Test-Path $csvfile) -eq $false) {
		
		# Show warning if db name is not pssqlbulkcopy and -Force was not specified
		if ($dataset -eq "verylarge") {
			$message = "The 'verylarge' dataset requires a 1.2GB download, a extracted 3GB CSV, and will create a 6GB database."
			$question = "Are you sure you want to continue?"
			$choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
			$choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
			$choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))
			
			$decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
			if ($decision -eq 1) { return }
		}
	
		Write-Output "Going grab the CSV zip file from OneDrive."
		Write-Output "This will only happen once unless $csvfile is deleted."
		Write-Output "Unfortunately there's no progress bar."
		Write-Output "Invoke-WebRequest has one but it drastically slows the transfer and Start-BitsTransfer doesn't work."
		
		if ($dataset -eq "verylarge") { Write-Warning "Go grab some coffee, probably. The 'verylarge' dataset is a 1.2 GB download from OneDrive, and then a pretty slow extraction because it's so compressed." }
		Add-Type -Assembly "System.Io.Compression.FileSystem"
		$zipfile = "$([Environment]::GetFolderPath('MyDocuments'))\pssqlbulkinsert-speedtest.zip"
		$WebClient = New-Object System.Net.WebClient
		$WebClient.DownloadFile($onedriveurl,$zipfile)
		Write-Output "Download complete. Unzipping."
		[Io.Compression.ZipFile]::ExtractToDirectory($zipfile, [Environment]::GetFolderPath('MyDocuments'))
		Write-Output "Deleteing zip"
		Remove-Item $zipfile
	}
	
	if ($nodbdrop -eq $false) {
		Write-Output "Dropping and recreating database $database. This ensures that the database has optimized properties."
		Restore-TestDb
	}
	
	if ($append -eq $false) { New-Table }


	# Clear cache.
	Clear-DbCache
	
	# Check network packetsize. This doesn't make a big impact for me but it may in other environments.
	$packetsize = Get-SqlPacketSize
	if ($packetsize -ne 4096) {
		Write-Output "Changing connectionstring's default packet size to match SQL Server: $packetsize"
		$conn.Close()
		$connectionString = "$connectionString;Packet Size=$packetsize"
		$conn.ConnectionString = $connectionString
		$conn.Open()
		$cmd.Connection = $conn
	}
	
<#

	Data processing section

#>

	# Setup datatable since SqlBulkCopy.WriteToServer can consume it
	$datatable = New-Object System.Data.DataTable
	$columns = (Get-Content $csvfile -First 1).Split("`t") 
	foreach ($column in $columns) { 
		$null = $datatable.Columns.Add()
	}

	# Update connection string for bulkinsert
	$connectionString = $connectionString -Replace "master", $database
	
	# Setup runspace pool and the scriptblock that runs inside each runspace
	$pool = [RunspaceFactory]::CreateRunspacePool($MinRunspaces,$MaxRunspaces)
	$pool.ApartmentState = $apartmentstate
	$pool.CleanupInterval =  (New-TimeSpan -Minutes 1)
	$pool.Open()
	$runspaces = [System.Collections.ArrayList]@()
		
	if (!$NoThreadReuse) { $Host.Runspace.ThreadOptions = "ReuseThread" }
		
		# This is the workhorse.
	$scriptblock = {
	   Param (
		[string]$connectionString,
		[object]$dtbatch,
		[string]$bulkoptions,
		[int]$batchsize,
		[string]$table,
		[bool]$enablestreaming
	   )
	   
		$bulkcopy = New-Object Data.SqlClient.SqlBulkCopy($connectionstring,$bulkoptions)
		$bulkcopy.DestinationTableName = $table
		$bulkcopy.BatchSize = $batchsize
		
		if ($enablestreaming -eq $true) {
			$bulkcopy.EnableStreaming = $true
		}
		
		$bulkcopy.WriteToServer($dtbatch)
		$bulkcopy.Close()
		$dtbatch.Clear()
		$bulkcopy.Dispose()
		$dtbatch.Dispose()
		return $error
	}

	Write-Output "Starting insert. Timer begins now."
	$elapsed = [System.Diagnostics.Stopwatch]::StartNew()

	# Use StreamReader to process csv file. Efficiently add each row to the datatable.
	# Once batchsize is reached, send it off to a runspace to be processed, then create a new datatable.
	# so that the one in the runspace doesn't get altered. Thanks Dave Wyatt for that suggestion!
	 
	$reader = New-Object System.IO.StreamReader($csvfile)

	while (($line = $reader.ReadLine()) -ne $null)  {
		$null = $datatable.Rows.Add($line.Split("`t"))
		
		if ($datatable.rows.count % $batchsize -eq 0) {
		#Write-Output "Wrote $batchsize to console"
		   $runspace = [PowerShell]::Create()
		   $null = $runspace.AddScript($scriptblock)
		   $null = $runspace.AddArgument($connectionString)
		   $null = $runspace.AddArgument($datatable)
		   $null = $runspace.AddArgument($bulkoptions)
		   $null = $runspace.AddArgument($batchsize)
		   $null = $runspace.AddArgument($table)
		   $null = $runspace.AddArgument($enablestreaming)
		   $runspace.RunspacePool = $pool
		   [void]$runspaces.Add([PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() })
		   # overwrite the datatable 
		   $datatable = $datatable.Clone()
		}
	}

	$reader.close()

	# Process any remaining rows
	if ($datatable.rows.count -gt 0) {
		$bulkcopy = New-Object Data.SqlClient.SqlBulkCopy($connectionstring)
		$bulkcopy.DestinationTableName = $table
		$bulkcopy.BulkCopyTimeout = 0
		$bulkcopy.WriteToServer($datatable)
		$bulkcopy.Close()
		$datatable.Clear()
	}

	# Wait for runspaces to complete
	while ($runspaces.Status.IsCompleted -notcontains $true) {}
	$secs = $elapsed.Elapsed.TotalSeconds
	Write-Output "Timer complete"
	
	if ($showerrors -eq $true) {
		$errors =  [System.Collections.ArrayList]@()
		foreach ($runspace in $runspaces) { 
			[void]$errors.Add($runspace.Pipe.EndInvoke($runspace.Status))
			$runspace.Pipe.Dispose()
		}
		$errors 
	}
	else {
		foreach ($runspace in $runspaces ) { 
			$null = $runspace.Pipe.EndInvoke($runspace.Status)
			$runspace.Pipe.Dispose()
		}
	}
	
	$pool.Close() 
	$pool.Dispose()
	
}
	
	END
	{
		if ($secs -gt 0) {
				$total = Get-Rowcount
				
				if ($total -ne 1000000 -and $total -ne 25000000) {
					Write-Warning "Some rows were dropped."
				}
				# Write out stats for million row csv file
				$rs = "{0:N0}" -f [int]($total / $secs)
				$rm = "{0:N0}" -f [int]($total / $secs * 60)
				$ram =  "{0:N2}" -f $((Get-Process -PID $pid).WorkingSet64/1GB)
				$mill = "{0:N0}" -f $total
				
				if ($dataset -eq "verylarge") {
					Write-Output "Memory usage is now at $ram GB, which can take up to 6 minutes to clear."
					Write-Output "You can now run the following to clear memory:`n    1..3 | foreach { [System.GC]::Collect() }"
				} else {
					Write-Output "Collecting garbage"
					Invoke-GarbageCollection
				}
				
				Write-Output "$mill rows imported in $([math]::round($secs,2)) seconds ($rs rows/sec and $rm rows/min)"	
			}
			# Close pools
		if ($conn.State -eq "Open") { 
			$conn.Close()
			$conn.Dispose()
			[System.Data.SqlClient.SqlConnection]::ClearAllPools()
		}
	}
}
