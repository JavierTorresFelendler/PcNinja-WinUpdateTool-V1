using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

[assembly: AssemblyTitle("PcNinja WinUpdate Tool CLI")]
[assembly: AssemblyCompany("PcNinja")]
[assembly: AssemblyProduct("PcNinja WinUpdate Tool")]
[assembly: AssemblyCopyright("Copyright (c) PcNinja")]
[assembly: AssemblyVersion("1.1.2.0")]
[assembly: AssemblyFileVersion("1.1.2.0")]
[assembly: AssemblyInformationalVersion("1.1.2.0")]

internal static class WinUpdateToolCli
{
    private const string Version = "1.1.2.0";

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0 || IsHelpRequest(args))
            {
                WriteHelp();
                return 0;
            }

            string appDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(appDir, "WinUpdateTool.ps1");

            if (!File.Exists(scriptPath))
            {
                Console.Error.WriteLine("WinUpdateTool.ps1 was not found beside the CLI executable.");
                return 2;
            }

            if (IsMode(args, "UI"))
            {
                return StartGuiHost(appDir);
            }

            return RunPowerShellCli(scriptPath, appDir, NormalizePowerShellArguments(args));
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("PcNinja WinUpdate Tool CLI failed: " + ex.Message);
            return 1;
        }
    }

    private static int StartGuiHost(string appDir)
    {
        string hostExe = Path.Combine(appDir, "PcNinja.WinUpdateTool.exe");
        if (!File.Exists(hostExe))
        {
            Console.Error.WriteLine("PcNinja.WinUpdateTool.exe was not found beside the CLI executable.");
            return 2;
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = hostExe;
        startInfo.WorkingDirectory = appDir;
        startInfo.UseShellExecute = true;
        Process.Start(startInfo);
        return 0;
    }

    private static int RunPowerShellCli(string scriptPath, string workingDirectory, string[] scriptArgs)
    {
        string powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe");

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = powershell;
        startInfo.WorkingDirectory = workingDirectory;
        startInfo.UseShellExecute = false;
        startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + QuoteArgument(scriptPath) + " " + JoinArguments(scriptArgs);

        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static string[] NormalizePowerShellArguments(string[] args)
    {
        List<string> normalized = new List<string>();

        foreach (string arg in args)
        {
            if (!String.IsNullOrEmpty(arg) && arg.StartsWith("/", StringComparison.Ordinal) && arg.Length > 1 && arg != "/?")
            {
                normalized.Add("-" + arg.Substring(1));
                continue;
            }

            normalized.Add(arg);
        }

        return normalized.ToArray();
    }

    private static bool IsHelpRequest(string[] args)
    {
        foreach (string arg in args)
        {
            if (String.Equals(arg, "/?", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(arg, "-?", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(arg, "--help", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(arg, "-help", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(arg, "/help", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsMode(string[] args, string mode)
    {
        for (int index = 0; index < args.Length - 1; index++)
        {
            if (String.Equals(args[index], "-Mode", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(args[index], "/Mode", StringComparison.OrdinalIgnoreCase))
            {
                return String.Equals(args[index + 1], mode, StringComparison.OrdinalIgnoreCase);
            }
        }

        return false;
    }

    private static void WriteHelp()
    {
        Console.WriteLine("PcNinja WinUpdate Tool CLI {0}", Version);
        Console.WriteLine();
        Console.WriteLine("Usage:");
        Console.WriteLine("  PcNinja.WinUpdateTool.Cli.exe /?");
        Console.WriteLine("  PcNinja.WinUpdateTool.Cli.exe -Mode Status -Json");
        Console.WriteLine("  PcNinja.WinUpdateTool.Cli.exe -Mode DriverAudit -Json");
        Console.WriteLine("  PcNinja.WinUpdateTool.Cli.exe -Mode CollectLogs -OutputPath C:\\Temp -Json");
        Console.WriteLine("  PcNinja.WinUpdateTool.Cli.exe -Mode RunUpdates -Silent -RunType Manual -Json");
        Console.WriteLine("  PcNinja.WinUpdateTool.Cli.exe -Mode ResetWindowsUpdate -ConfirmReset -Json");
        Console.WriteLine("  PcNinja.WinUpdateTool.Cli.exe -Mode Configure -EnableSchedule -Frequency Monthly -MonthlyDay 15 -Time 03:00 -WakeToRun");
        Console.WriteLine("  PcNinja.WinUpdateTool.Cli.exe -Mode Configure -ConfigFile C:\\Temp\\pcninja-install.json -Json");
        Console.WriteLine();
        Console.WriteLine("Modes:");
        Console.WriteLine("  UI, Status, RunUpdates, ResetWindowsUpdate, Configure, DriverAudit, DriverReport, CollectLogs, ShowLog, RunOnceTask");
        Console.WriteLine();
        Console.WriteLine("Common options:");
        Console.WriteLine("  -Json");
        Console.WriteLine("  -ConfigFile <json path>");
        Console.WriteLine("  -LogTail <lines>");
        Console.WriteLine("  -Silent");
        Console.WriteLine("  -RunType Manual|Scheduled|Retry|Startup|Wake");
        Console.WriteLine("  -AllowStopBackgroundActivity");
        Console.WriteLine("  -ConfirmReset");
        Console.WriteLine("  -ForceReset");
        Console.WriteLine();
        Console.WriteLine("Schedule options:");
        Console.WriteLine("  -EnableSchedule | -DisableSchedule");
        Console.WriteLine("  -Frequency Daily|Weekly|Monthly|Startup");
        Console.WriteLine("  -Time HH:mm");
        Console.WriteLine("  -DayOfWeek Sunday..Saturday");
        Console.WriteLine("  -MonthlyDay 1..28");
        Console.WriteLine("  -RunAtStartup | -NoRunAtStartup");
        Console.WriteLine("  -StartupDelayMinutes <minutes>");
        Console.WriteLine("  -RunIfMissed | -NoRunIfMissed");
        Console.WriteLine("  -WakeToRun | -NoWakeToRun");
        Console.WriteLine();
        Console.WriteLine("Retry/options:");
        Console.WriteLine("  -EnableAutoRetry | -DisableAutoRetry");
        Console.WriteLine("  -RetryInitialDelayMinutes <minutes>");
        Console.WriteLine("  -RetryMaxAttempts <count>");
        Console.WriteLine("  -RetryBackoffMultiplier <number>");
        Console.WriteLine("  -MinimumCooldownMinutes <minutes>");
        Console.WriteLine("  -EnableRebootPrompt | -DisableRebootPrompt");
        Console.WriteLine("  -EnableFirmwareUpdates | -DisableFirmwareUpdates");
        Console.WriteLine();
        Console.WriteLine("Notes:");
        Console.WriteLine("  Status and DriverAudit can run without elevation.");
        Console.WriteLine("  Configure, RunUpdates, and scheduled-task operations should run elevated.");
        Console.WriteLine("  The GUI entry point is PcNinja.WinUpdateTool.exe.");
    }

    private static string JoinArguments(string[] args)
    {
        List<string> quoted = new List<string>();

        foreach (string arg in args)
        {
            quoted.Add(QuoteArgument(arg));
        }

        return String.Join(" ", quoted.ToArray());
    }

    private static string QuoteArgument(string arg)
    {
        if (arg == null || arg.Length == 0)
        {
            return "\"\"";
        }

        if (arg.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return arg;
        }

        StringBuilder builder = new StringBuilder();
        builder.Append('"');

        int backslashCount = 0;

        foreach (char character in arg)
        {
            if (character == '\\')
            {
                backslashCount++;
                continue;
            }

            if (character == '"')
            {
                builder.Append('\\', (backslashCount * 2) + 1);
                builder.Append('"');
                backslashCount = 0;
                continue;
            }

            builder.Append('\\', backslashCount);
            builder.Append(character);
            backslashCount = 0;
        }

        builder.Append('\\', backslashCount * 2);
        builder.Append('"');
        return builder.ToString();
    }
}









