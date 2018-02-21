<# Exchange User Maintenance Script
Operations:
	*Add/Install SQL Module
	*Loop though all MDF files on directory 
	*Mount all Databases
	*Add all users of those databases to SQL server
	*Upgrade Database compatibility
Dependencies for this script:
	*SQLPS or SQLServer powershell module
Changes:
	*Updated code to use use newer SQL powershell commands and cleaned up code -version 1.0.2

#>
#region Variable Setup
#############################################################################
# User Variables
#############################################################################
param (
	[string]$mdf = "",
	[string]$ldf = "",
	[string]$Server = "localhost",
	[string]$Instance  = "Default"
)
$ScriptVersion = "1.0.2"

$LogFile = ((Split-Path -Parent -Path $MyInvocation.MyCommand.Definition) + "\" + `
		$MyInvocation.MyCommand.Name + "_" + `
		(Get-Date -format yyyyMMdd-hhmm) + ".log")
#############################################################################
#endregion

# Run as Administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
  # Relaunch as an elevated process:
  Start-Process powershell.exe "-File",('"{0}"' -f $MyInvocation.MyCommand.Path) -Verb RunAs
  exit
}
$ErrorActionPreference = "Stop"
#Log setup
If (-Not [string]::IsNullOrEmpty($LogFile)) {
	Start-Transcript -Path $LogFile -Append
	Write-Host ("Script: " + $MyInvocation.MyCommand.Name)
	Write-Host ("Version: " + $ScriptVersion)
	Write-Host (" ")
}

#region Module Setup
cd $env:temp #Issue with C:\windows\system32 default and "SqlServer" module
If (Get-Module -Name sqlserver)
{

}else{
	If (Import-Module "SqlServer" -ErrorAction SilentlyContinue)
	{
		Write-Host "Loading SqlServer Module"
	} else {
		If (Get-Module -Name "sqlps") {
			Write-Host "SQLPS Module Already Loaded"
		}else{
			If (Import-Module "sqlps" -ErrorAction SilentlyContinue)
			{
				Write-Host "Loading SQLPS Module"
			} else {
				If (!(Get-Module -Name "sqlps")) {
					#throw "SQL Server Provider for Windows PowerShell is not installed."	
					Write-Host "Installing SQL Modules . . ."
					#Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Verbose -Force
					#Install-Module -Name SqlServer -Force -AllowClobber
					Import-Module "SqlServer"	
				}
			}
		}
	}
}
#endregion


#region Validate Variable 

If (!(Test-Path -Path $mdf)) 
{
	throw "Bad MDF file path: $mdf"	
}
If (!(Test-Path -Path $ldf)) 
{
	throw "Bad LDF file path: $ldf"	
}
If (!(Test-Connection -ComputerName $Server -Quiet))
{
	throw "No connection to server: $Server"
}
#endregion
#SQL Object
$sql = get-item ("SQLSERVER:\SQL\" + $Server + "\" + $Instance)

#loop though mdf files
foreach ($i in get-childitem ($mdf +"\*.*") -include *.mdf,*.MDF)
{
	$dbnameraw = $i.name.substring(0,$i.name.length -4)
	if ($dbnameraw.contains("_Data")) 
	{
	 $dbname = $dbnameraw.substring(0,$dbnameraw.length -5)
	}
	else
	{
	 $dbname = $dbnameraw
	}
	#See if Database exists in array
	
	if ( $sql.Databases.Name -notcontains $dbname )
	{	
		Write-Host ("Attaching database: " + $dbname) -foregroundcolor "Green"
		#Attach Database
		$sc = new-object System.Collections.Specialized.StringCollection
		$sc.Add($mdf + "\" + $dbnameraw + ".mdf") | Out-Null 
		$sc.Add($ldf + "\" + $dbname + "_log.ldf") | Out-Null
		Write-Host ("`t" + $sc) -foregroundcolor "Gray"
		$sql.AttachDatabase($dbname, $sc)
		# Set compatibility level to 100
		$db = New-Object Microsoft.SqlServer.Management.Smo.Database
		$db = $sql.Databases.Item($dbname)
		$sql.Refresh() | Out-Null
		$cl = New-Object Microsoft.SqlServer.Management.Smo.CompatibilityLevel
		$cl = $db.CompatiblityLevel
		$oldCL = ""
		$oldCL = $db.CompatibilityLevel 
		$db.CompatibilityLevel = [Microsoft.SqlServer.Management.Smo.CompatibilityLevel]'Version100'
		$db.Alter()
		Write-Host ("`tCompatibility level =" + $oldCL + "`tNew Compatibility level =" + $db.CompatibilityLevel ) -foregroundcolor "gray"
		# List users:
		$sql.Refresh()
		foreach  ($user in $sql.Databases[$dbname].users )
		{
			Write-Host "`t  Username = " $user.name " Login= " $user.Login "DefaultSchema= " $user.DefaultSchema
			if ((($sql.Logins | where {$_.Name -eq $user.name}) -ne $null) -or (($sql.Logins | where {$_.Name -eq $user.Login}) -ne $null))
			{
				Write-Host "`t`tUser Exsits in SQL: " $user.name  -foregroundcolor "gray"
			}
			else
			{
				if (($user.Login.Contains("\")) -and (!$user.Login.StartsWith("BUILTIN\")) -and (!$user.Login.StartsWith("NT AUTHORITY\")))
				{
					$Account = $user.Login.substring(6,$user.Login.length -6 )
					#Write-Host $Account
					$searcher = new-object System.DirectoryServices.DirectorySearcher("(sAMAccountName=$Account)")
					$aduser=$searcher.FindOne().GetDirectoryEntry()
					#Write-Host $aduser.name
					if($($aduser.userAccountControl) -band 0x2)
					{
						#Disabled account
						#Remove User:
						$SqlConn = New-Object System.Data.SqlClient.SqlConnection
						$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
						try{
							$SqlConn.ConnectionString = "Server=" + $InstConn+ ";Database=" + $dbname + ";Integrated Security=True"
							$sqlconn.Open()
							$SqlCmd.Connection = $SqlConn
							$SqlCmd.CommandText = "USE [" + $dbname + "]"
							$SqlCmd.ExecuteNonQuery() | Out-Null 
							$SqlCmd.CommandText = "sp_revokedbaccess '" + $user.name + "'"
							$SqlCmd.ExecuteNonQuery() | Out-Null 
							$SqlConn.Close()
							Write-Host -foregroundcolor yellow "`t`tAD Account Removed: " $user.name
						} catch {
									$msg = $error[0]
									Write-Warning $msg
									Write-Host -foregroundcolor red "`t`tAD Account Needs to be removed: " $user.name
						}           
					}
					else
					{
						#Active Account
						#Create User in SQL System
						$SqlConn = New-Object System.Data.SqlClient.SqlConnection
						$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
						try{
							$SqlConn.ConnectionString = "Server=" + $InstConn+ ";Database=" + $dbname + ";Integrated Security=True"
							$sqlconn.Open()
							$SqlCmd.Connection = $SqlConn
							$SqlCmd.CommandText = "CREATE LOGIN ["+$user.Login+"] FROM WINDOWS WITH DEFAULT_DATABASE=[MASTER], DEFAULT_LANGUAGE=[us_english]"
							$SqlCmd.ExecuteNonQuery() | Out-Null 
							$SqlConn.Close()
							write-host -foregroundcolor green "`t`tAD Account added: " $user.name
						} catch {
									$msg = $error[0]
									Write-Warning $msg
									write-host -foregroundcolor red "`t`tAD Account Needs to be added: " $user.name
						}           
						
					}
				}
				else
				{
					switch ($user.name)
					{
						dbo {Write-Host ("`t`tSQL System Account:" $user.name) -foregroundcolor "gray"}
						sys {Write-Host ("`t`tSQL System Account:" $user.name) -foregroundcolor "gray"}
						INFORMATION_SCHEMA {Write-Host ("`t`tSQL System Account:" $user.name) -foregroundcolor "gray"}
						guest {Write-Host ("`t`tSQL System Account:" $user.name) -foregroundcolor "gray"}
						default {
								$Account = $user.name
								try{
									#Write-Host $Account
									$searcher = new-object System.DirectoryServices.DirectorySearcher("(sAMAccountName=$Account)")
									$aduser=$searcher.FindOne().GetDirectoryEntry()
								} catch {
									$aduser=""
								}
								#Write-Host $aduser.name
								if ($aduser.Properties.samaccountname -eq $user.name )
								{
									if($($aduser.userAccountControl) -band 0x2)
									{
										#Disabled account
										
										#Remove User:
										$SqlConn = New-Object System.Data.SqlClient.SqlConnection
										$SqlCmd = New-Object System.Data.SqlClient.SqlCommand
										try{
											$SqlConn.ConnectionString = "Server=" + $InstConn+ ";Database=" + $dbname + ";Integrated Security=True"
											$sqlconn.Open()
											$SqlCmd.Connection = $SqlConn
											$SqlCmd.CommandText = "USE [" + $dbname + "]"
											$SqlCmd.ExecuteNonQuery() | Out-Null 
											$SqlCmd.CommandText = "sp_revokedbaccess '" + $user.name + "'"
											$SqlCmd.ExecuteNonQuery() | Out-Null 
											$SqlConn.Close()
											Write-Host -foregroundcolor green "`t`tSQL Account removed: " $user.name
										} catch {
													$msg = $error[0]
													Write-Warning $msg
										}           
									}
									else
									{
									#Active Account
									#SQL logon and not AD Logon
									
									#Create AD Logon
									
									#Clone user Rights
									
									#Remove SQL logon
									Write-Host -foregroundcolor DarkGray "          SQL Logon needs to be converted to AD Logon: " $user.name
									}
								}
								else
								{
									write-host -foregroundcolor DarkGray "          SQL Account Needs to be added: " $user.name

								}
							}
					}
				}
			}
		}
	
	
	}
	else
	{
		Write-Host "Database Exists: "$dbname
	}
}

If (-Not [string]::IsNullOrEmpty($LogFile)) {
	Stop-Transcript
}
