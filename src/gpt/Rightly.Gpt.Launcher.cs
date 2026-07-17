using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Rightly GPT")]
[assembly: AssemblyDescription("Launches the official GPT Work / Codex app with Rightly RTL support")]
[assembly: AssemblyCompany("Rightly")]
[assembly: AssemblyProduct("Rightly GPT")]
[assembly: AssemblyCopyright("Copyright © 2026 Rightly contributors")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace Rightly.Gpt
{
    internal static class Launcher
    {
        private const string AppUserModelId = "Rightly.GPT.Launcher";
        private const string MutexName = @"Local\Rightly.GPT.Launcher.Startup";

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [STAThread]
        private static int Main()
        {
            SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            bool ownsMutex;
            using (var mutex = new Mutex(true, MutexName, out ownsMutex))
            {
                if (!ownsMutex)
                {
                    Application.Run(StatusWindow.CreateAlreadyStartingNotice());
                    return 0;
                }

                try
                {
                    using (var window = new StatusWindow())
                    {
                        Application.Run(window);
                        return window.ExitCode;
                    }
                }
                finally
                {
                    mutex.ReleaseMutex();
                }
            }
        }
    }

    internal sealed class StatusWindow : Form
    {
        private static readonly Color Navy = Color.FromArgb(6, 27, 79);
        private static readonly Color Orange = Color.FromArgb(255, 90, 42);
        private static readonly Color Muted = Color.FromArgb(91, 101, 116);

        private readonly Label statusLabel;
        private readonly Label detailLabel;
        private readonly ProgressBar progressBar;
        private readonly Button closeButton;
        private readonly System.Windows.Forms.Timer statusTimer;
        private readonly bool noticeOnly;
        private System.Windows.Forms.Timer completionTimer;
        private string statusPath;
        private string lastStatusCode = "";

        public int ExitCode { get; private set; }

        public StatusWindow()
            : this(false)
        {
        }

        private StatusWindow(bool noticeOnly)
        {
            this.noticeOnly = noticeOnly;
            ExitCode = 0;
            Text = "Rightly GPT";
            ClientSize = new Size(500, 230);
            MinimumSize = MaximumSize = Size;
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            BackColor = Color.White;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

            var accent = new Panel { BackColor = Orange, Dock = DockStyle.Left, Width = 6 };
            Controls.Add(accent);

            var header = new Panel { BackColor = Navy, Dock = DockStyle.Top, Height = 68 };
            var logo = new PictureBox
            {
                Image = Icon.ToBitmap(),
                Location = new Point(24, 14),
                Size = new Size(40, 40),
                SizeMode = PictureBoxSizeMode.StretchImage
            };
            var title = new Label
            {
                AutoSize = true,
                ForeColor = Color.White,
                Font = new Font("Segoe UI Semibold", 16F),
                Location = new Point(76, 18),
                Text = "Rightly GPT"
            };
            header.Controls.Add(logo);
            header.Controls.Add(title);
            Controls.Add(header);

            statusLabel = new Label
            {
                AutoSize = false,
                Font = new Font("Segoe UI Semibold", 12F),
                ForeColor = Navy,
                Location = new Point(30, 91),
                Size = new Size(440, 29),
                Text = noticeOnly ? "Rightly GPT is already starting" : "Checking GPT..."
            };
            detailLabel = new Label
            {
                AutoSize = false,
                Font = new Font("Segoe UI", 9.5F),
                ForeColor = Muted,
                Location = new Point(30, 123),
                Size = new Size(440, 42),
                Text = noticeOnly
                    ? "Another launch is already in progress. GPT will open shortly."
                    : "Rightly is checking whether the running GPT window is already corrected."
            };
            progressBar = new ProgressBar
            {
                Location = new Point(30, 174),
                Size = new Size(440, 8),
                Style = ProgressBarStyle.Marquee,
                MarqueeAnimationSpeed = 24
            };
            closeButton = new Button
            {
                Location = new Point(378, 188),
                Size = new Size(92, 30),
                Text = "Close",
                Visible = false
            };
            closeButton.Click += delegate { Close(); };
            Controls.Add(statusLabel);
            Controls.Add(detailLabel);
            Controls.Add(progressBar);
            Controls.Add(closeButton);

            statusTimer = new System.Windows.Forms.Timer { Interval = 180 };
            statusTimer.Tick += delegate { RefreshStatus(); };
            Shown += OnWindowShown;
            FormClosed += delegate { CleanupStatusFile(); };
        }

        public static StatusWindow CreateAlreadyStartingNotice()
        {
            return new StatusWindow(true);
        }

        private void OnWindowShown(object sender, EventArgs eventArgs)
        {
            if (noticeOnly)
            {
                completionTimer = new System.Windows.Forms.Timer { Interval = 2200 };
                completionTimer.Tick += delegate
                {
                    completionTimer.Stop();
                    Close();
                };
                completionTimer.Start();
                return;
            }

            string installDirectory = AppDomain.CurrentDomain.BaseDirectory;
            string logDirectory = Path.Combine(installDirectory, "logs");
            Directory.CreateDirectory(logDirectory);
            statusPath = Path.Combine(logDirectory, "launcher-status-" + Process.GetCurrentProcess().Id + ".txt");
            statusTimer.Start();

            var worker = new BackgroundWorker();
            worker.DoWork += delegate(object workerSender, DoWorkEventArgs args)
            {
                args.Result = RunPowerShellLauncher(installDirectory, statusPath);
            };
            worker.RunWorkerCompleted += OnLauncherCompleted;
            worker.RunWorkerAsync();
        }

        private static int RunPowerShellLauncher(string installDirectory, string statusFile)
        {
            string launcherScript = Path.Combine(installDirectory, "launch-gpt.ps1");
            string logPath = Path.Combine(installDirectory, "logs", "gpt-launcher.log");
            try
            {
                if (!File.Exists(launcherScript))
                {
                    throw new FileNotFoundException("Rightly's GPT launcher script is missing.", launcherScript);
                }

                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");
                var startInfo = new ProcessStartInfo
                {
                    FileName = powershell,
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " +
                        Quote(launcherScript) + " -StatusFile " + Quote(statusFile),
                    WorkingDirectory = installDirectory,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                using (Process process = Process.Start(startInfo))
                {
                    if (process == null) throw new InvalidOperationException("Windows could not start Rightly GPT.");
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception exception)
            {
                TryWriteError(logPath, exception);
                TryWriteStatus(statusFile, "failed", exception.Message);
                return 1;
            }
        }

        private void RefreshStatus()
        {
            if (String.IsNullOrEmpty(statusPath) || !File.Exists(statusPath)) return;
            try
            {
                string[] lines = File.ReadAllLines(statusPath, Encoding.UTF8);
                if (lines.Length == 0 || lines[0] == lastStatusCode) return;
                lastStatusCode = lines[0];
                string message = lines.Length > 1 ? String.Join(" ", lines, 1, lines.Length - 1) : "";
                ApplyStatus(lastStatusCode, message);
            }
            catch
            {
                // The writer may be replacing the tiny status file; retry on the next tick.
            }
        }

        private void ApplyStatus(string code, string message)
        {
            string title;
            switch (code)
            {
                case "checking": title = "Checking the running GPT window"; break;
                case "restarting": title = "Restarting GPT with Rightly"; break;
                case "preparing": title = "Preparing secure RTL startup"; break;
                case "opening": title = "Opening the official GPT app"; break;
                case "injecting": title = "Applying and verifying RTL support"; break;
                case "ready": title = "Rightly is active"; break;
                case "failed": title = "Rightly could not start GPT"; break;
                default: title = "Starting Rightly GPT"; break;
            }
            statusLabel.Text = title;
            if (!String.IsNullOrWhiteSpace(message)) detailLabel.Text = message;
        }

        private void OnLauncherCompleted(object sender, RunWorkerCompletedEventArgs eventArgs)
        {
            statusTimer.Stop();
            RefreshStatus();
            ExitCode = eventArgs.Error == null ? (int)eventArgs.Result : 1;
            if (ExitCode == 0)
            {
                ApplyStatus("ready", "GPT is open with a verified Rightly correction.");
                progressBar.Style = ProgressBarStyle.Continuous;
                progressBar.Value = 100;
                completionTimer = new System.Windows.Forms.Timer { Interval = 1100 };
                completionTimer.Tick += delegate
                {
                    completionTimer.Stop();
                    Close();
                };
                completionTimer.Start();
            }
            else
            {
                if (lastStatusCode != "failed")
                {
                    ApplyStatus("failed", eventArgs.Error != null
                        ? eventArgs.Error.Message
                        : "See the Rightly GPT log for details.");
                }
                progressBar.Visible = false;
                closeButton.Visible = true;
            }
        }

        private void CleanupStatusFile()
        {
            statusTimer.Stop();
            if (completionTimer != null)
            {
                completionTimer.Stop();
                completionTimer.Dispose();
                completionTimer = null;
            }
            if (String.IsNullOrEmpty(statusPath)) return;
            try { File.Delete(statusPath); } catch { }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static void TryWriteStatus(string path, string code, string message)
        {
            try { File.WriteAllLines(path, new[] { code, message }, Encoding.UTF8); } catch { }
        }

        private static void TryWriteError(string logPath, Exception exception)
        {
            try
            {
                string logDirectory = Path.GetDirectoryName(logPath);
                if (!String.IsNullOrEmpty(logDirectory)) Directory.CreateDirectory(logDirectory);
                File.AppendAllText(
                    logPath,
                    DateTimeOffset.Now.ToString("o") + " " + exception + Environment.NewLine,
                    Encoding.UTF8);
            }
            catch { }
        }
    }
}
