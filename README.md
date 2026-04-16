# Entra Endpoint Toolkit

PowerShell toolkit for managing devices, users, and groups across Microsoft Entra ID, Intune, and on-prem Active Directory.

## Overview

This repository contains a collection of administrative scripts designed to simplify endpoint and identity management tasks across hybrid environments.

The scripts focus on:

* Device lifecycle management
* User-to-device relationships
* Cross-system consistency (Entra ID, Intune, AD, Defender)
* Group automation and bulk operations

## Structure

* `/scripts/users` — User-related operations
* `/scripts/devices` — Device inventory and comparison
* `/scripts/groups` — Group management and automation
* `/modules` — Shared/reusable functions (in progress)
* `/examples` — Sample input files

## Key Capabilities

* Manage user device ownership, registration & primary users (Intune)
* Compare device presence across multiple systems
* Export device data from groups (including nested groups)
* Automate group creation with devices based on user attributes (e.g., location)
* Bulk add devices to groups from file input
* Identify primary devices per user

## Requirements

* PowerShell 5.1 or newer
* Microsoft Graph PowerShell SDK
* Appropriate permissions for:

  * Entra ID
  * Intune
  * Active Directory (if applicable)

## Usage

Each script is standalone and can be executed directly.

Example:

```powershell
.\scripts\users\Set-UserDeviceOwnership.ps1
```

Some scripts require input files.

## Notes

* These scripts are intended for administrative use in enterprise environments
* Test in a non-production environment before use
* Authentication and common functions will be standardized over time

## License

MIT License
