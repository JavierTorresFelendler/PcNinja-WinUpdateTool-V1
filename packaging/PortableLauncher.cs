using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("PcNinja WinUpdate Tool Portable")]
[assembly: AssemblyCompany("PcNinja")]
[assembly: AssemblyProduct("PcNinja WinUpdate Tool")]
[assembly: AssemblyCopyright("Copyright (c) PcNinja")]
[assembly: AssemblyVersion("1.1.3.0")]
[assembly: AssemblyFileVersion("1.1.3.0")]
[assembly: AssemblyInformationalVersion("V1.1.3-RC1")]

internal static class PortableLauncher
{
    private const string Version = "1.1.3.0";
    private const string PayloadResourceName = "PcNinjaPortablePayload";

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (IsHelpRequest(args))
            {
                if (ShouldWriteHelpToConsole())
                {
                    WriteHelp();
                }
                else
                {
                    HideConsoleWindow();
                    ShowHelpWindow();
                }

                return 0;
            }

            HideConsoleForDoubleClickGui(args);

            string extractRoot = GetExtractRoot();
            Directory.CreateDirectory(extractRoot);
            ExtractPayload(extractRoot);

            if (args.Length == 0)
            {
                LaunchGui(extractRoot);
                return 0;
            }

            return LaunchCli(extractRoot, args);
        }
        catch (Exception ex)
        {
            if (args.Length == 0)
            {
                MessageBox.Show(
                    "PcNinja WinUpdate Tool portable launcher failed:\r\n\r\n" + ex.Message,
                    "PcNinja WinUpdate Tool",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
            else
            {
                Console.Error.WriteLine("PcNinja WinUpdate Tool portable launcher failed: " + ex.Message);
            }

            return 1;
        }
    }

    private static string GetExtractRoot()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "PcNinja", "WinUpdateTool", "Portable", Version);
    }

    private static void ExtractPayload(string extractRoot)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();

        using (Stream payloadStream = assembly.GetManifestResourceStream(PayloadResourceName))
        {
            if (payloadStream == null)
            {
                throw new InvalidOperationException("Embedded portable payload was not found.");
            }

            using (ZipArchive archive = new ZipArchive(payloadStream, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string targetPath = Path.GetFullPath(Path.Combine(extractRoot, entry.FullName));
                    string normalizedRoot = Path.GetFullPath(extractRoot + Path.DirectorySeparatorChar);

                    if (!targetPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidOperationException("Portable payload contains an invalid path.");
                    }

                    if (String.IsNullOrEmpty(entry.Name))
                    {
                        Directory.CreateDirectory(targetPath);
                        continue;
                    }

                    string targetDir = Path.GetDirectoryName(targetPath);
                    if (!String.IsNullOrEmpty(targetDir))
                    {
                        Directory.CreateDirectory(targetDir);
                    }

                    using (Stream source = entry.Open())
                    using (FileStream destination = new FileStream(targetPath, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        source.CopyTo(destination);
                    }
                }
            }
        }
    }

    private static void LaunchGui(string extractRoot)
    {
        string hostExe = Path.Combine(extractRoot, "PcNinja.WinUpdateTool.exe");
        if (!File.Exists(hostExe))
        {
            throw new FileNotFoundException("PcNinja.WinUpdateTool.exe was not found after extraction.", hostExe);
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = hostExe;
        startInfo.WorkingDirectory = extractRoot;
        startInfo.UseShellExecute = true;
        Process.Start(startInfo);
    }

    private static int LaunchCli(string extractRoot, string[] args)
    {
        string cliExe = Path.Combine(extractRoot, "PcNinja.WinUpdateTool.Cli.exe");
        if (!File.Exists(cliExe))
        {
            throw new FileNotFoundException("PcNinja.WinUpdateTool.Cli.exe was not found after extraction.", cliExe);
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = cliExe;
        startInfo.Arguments = JoinArguments(args);
        startInfo.WorkingDirectory = extractRoot;
        startInfo.UseShellExecute = false;

        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
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

    private static void WriteHelp()
    {
        Console.Write(GetHelpText());
    }

    private static void ShowHelpWindow()
    {
        Application.EnableVisualStyles();

        using (Form form = new Form())
        using (Label note = new Label())
        using (TextBox helpText = new TextBox())
        using (Button okButton = new Button())
        {
            form.Text = "PcNinja WinUpdate Tool CLI Help";
            form.StartPosition = FormStartPosition.CenterScreen;
            form.Size = new Size(780, 560);
            form.MinimumSize = new Size(640, 420);

            note.Text = "Use from Run, CMD, PowerShell, or deployment tools. The text box is selectable/copyable.";
            note.AutoSize = false;
            note.Location = new Point(18, 18);
            note.Size = new Size(724, 26);

            helpText.Multiline = true;
            helpText.ReadOnly = true;
            helpText.WordWrap = false;
            helpText.ScrollBars = ScrollBars.Both;
            helpText.Font = new Font("Consolas", 9F);
            helpText.Text = GetHelpText();
            helpText.Location = new Point(18, 54);
            helpText.Size = new Size(724, 400);
            helpText.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;

            okButton.Text = "OK";
            okButton.Size = new Size(104, 34);
            okButton.Location = new Point(638, 470);
            okButton.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
            okButton.DialogResult = DialogResult.OK;

            form.Controls.Add(note);
            form.Controls.Add(helpText);
            form.Controls.Add(okButton);
            form.AcceptButton = okButton;

            form.ShowDialog();
        }
    }

    private static string GetHelpText()
    {
        string executableName = Path.GetFileName(Application.ExecutablePath);
        if (String.IsNullOrWhiteSpace(executableName))
        {
            executableName = "PcNinja-WinUpdateTool-V1.1.3-RC1-Portable.exe";
        }

        StringBuilder builder = new StringBuilder();
        builder.AppendFormat("PcNinja WinUpdate Tool Portable {0}\r\n\r\n", Version);
        builder.AppendLine("Portable usage:");
        builder.AppendFormat("  {0}\r\n", executableName);
        builder.AppendFormat("  {0} /?\r\n", executableName);
        builder.AppendFormat("  {0} -Mode Status -Json\r\n", executableName);
        builder.AppendFormat("  {0} -Mode DriverAudit -Json\r\n", executableName);
        builder.AppendFormat("  {0} -Mode CollectLogs -OutputPath C:\\Temp -Json\r\n", executableName);
        builder.AppendFormat("  {0} -Mode RunUpdates -Silent -RunType Manual -Json\r\n", executableName);
        builder.AppendFormat("  {0} -Mode ResetWindowsUpdate -ConfirmReset -Json\r\n", executableName);
        builder.AppendFormat("  {0} -Mode Configure -ConfigFile C:\\Temp\\pcninja-install.json -Json\r\n", executableName);
        builder.AppendLine();
        builder.AppendLine("Portable extraction path:");
        builder.AppendFormat("  %LOCALAPPDATA%\\PcNinja\\WinUpdateTool\\Portable\\{0}\r\n", Version);
        builder.AppendLine();
        builder.AppendLine("Installed CLI:");
        builder.AppendLine("  %ProgramFiles%\\PcNinja\\WinUpdateTool\\PcNinja.WinUpdateTool.Cli.exe /?");
        builder.AppendLine("  %ProgramFiles%\\PcNinja\\WinUpdateTool\\PcNinja.WinUpdateTool.Cli.exe -Mode Status -Json");
        builder.AppendLine("  %ProgramFiles%\\PcNinja\\WinUpdateTool\\PcNinja.WinUpdateTool.Cli.exe -Mode ResetWindowsUpdate -ConfirmReset -Json");
        return builder.ToString();
    }

    private static string JoinArguments(string[] args)
    {
        if (args == null || args.Length == 0)
        {
            return String.Empty;
        }

        string[] quoted = new string[args.Length];

        for (int index = 0; index < args.Length; index++)
        {
            quoted[index] = QuoteArgument(args[index]);
        }

        return String.Join(" ", quoted);
    }

    private static string QuoteArgument(string arg)
    {
        if (String.IsNullOrEmpty(arg))
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

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern uint GetConsoleProcessList(uint[] processList, uint processCount);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    private static void HideConsoleForDoubleClickGui(string[] args)
    {
        if (args.Length > 0)
        {
            return;
        }

        IntPtr consoleWindow = GetConsoleWindow();
        if (consoleWindow == IntPtr.Zero)
        {
            return;
        }

        uint[] processList = new uint[8];
        uint processCount = GetConsoleProcessList(processList, (uint)processList.Length);

        if (processCount <= 1)
        {
            ShowWindow(consoleWindow, 0);
        }
    }

    private static bool HasParentConsole()
    {
        IntPtr consoleWindow = GetConsoleWindow();
        if (consoleWindow == IntPtr.Zero)
        {
            return false;
        }

        uint[] processList = new uint[8];
        uint processCount = GetConsoleProcessList(processList, (uint)processList.Length);
        return processCount > 1;
    }

    private static bool ShouldWriteHelpToConsole()
    {
        return HasParentConsole() ||
            Console.IsInputRedirected ||
            Console.IsOutputRedirected ||
            Console.IsErrorRedirected;
    }

    private static void HideConsoleWindow()
    {
        IntPtr consoleWindow = GetConsoleWindow();
        if (consoleWindow != IntPtr.Zero)
        {
            ShowWindow(consoleWindow, 0);
        }
    }
}









