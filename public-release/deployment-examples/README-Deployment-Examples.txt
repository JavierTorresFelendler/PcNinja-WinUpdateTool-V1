PcNinja WinUpdate Tool deployment examples

Files:
  Install-MSI-Silent-Basic.cmd
    Silent MSI install only.

  Install-MSI-Silent-WithProperties.cmd
    Silent MSI install plus post-install configuration using MSI properties.

  BigFix-Action-Example.cmd
    Single-line BigFix-style example. Adjust download paths for your action.

  Installed-CLI-Examples.cmd
    Examples for the installed CLI host.

  Portable-CLI-Examples.cmd
    Examples for the portable EXE CLI mode.

CMD line-continuation rule:
  The ^ character is only for CMD/BAT line continuation.
  It must be the final character on the line. Do not put spaces after it.
  For BigFix deployment, a single msiexec command line is usually safer.

JSON MSI deployment:
  Not included in this release. Use MSI properties for silent configuration.

MSI configuration properties:
  PCNINJA_ENABLE_SCHEDULE
  PCNINJA_FREQUENCY
  PCNINJA_TIME
  PCNINJA_DAY_OF_WEEK
  PCNINJA_MONTHLY_DAY
  PCNINJA_RUN_AT_STARTUP
  PCNINJA_STARTUP_DELAY
  PCNINJA_RUN_IF_MISSED
  PCNINJA_WAKE_TO_RUN
  PCNINJA_ALLOW_FIRMWARE
  PCNINJA_REBOOT_PROMPT
  PCNINJA_ENABLE_AUTORETRY
  PCNINJA_RETRY_INITIAL_DELAY
  PCNINJA_RETRY_MAX_ATTEMPTS
  PCNINJA_RETRY_BACKOFF
  PCNINJA_MINIMUM_COOLDOWN

Boolean MSI values:
  1/0, true/false, yes/no, and on/off are accepted.

Important:
  The MSI post-install configuration runs elevated as LocalSystem.
  MSI post-install configuration log:
  %ProgramData%\PcNinja\WinUpdateTool\Logs\MsiConfigure.log

