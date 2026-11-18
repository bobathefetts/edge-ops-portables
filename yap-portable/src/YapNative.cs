using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace YapNative
{
    public static class NativeHost
    {
        public static List<string> ListInputDevices()
        {
            List<string> list = new List<string>();
            uint count = waveInGetNumDevs();
            uint sz = (uint)Marshal.SizeOf(typeof(WAVEINCAPS));
            for (uint i = 0; i < count; i++)
            {
                WAVEINCAPS caps = new WAVEINCAPS();
                if (waveInGetDevCaps((IntPtr)i, ref caps, sz) == 0 && !string.IsNullOrEmpty(caps.szPname))
                {
                    list.Add(caps.szPname.Trim());
                }
            }
            return list;
        }

        public static void PasteText(string text, bool restoreClipboard)
        {
            if (string.IsNullOrEmpty(text)) return;

            string prevText = null;
            bool hadText = false;
            try
            {
                if (Clipboard.ContainsText())
                {
                    prevText = Clipboard.GetText();
                    hadText = true;
                }
            }
            catch { }

            for (int i = 0; i < 6; i++)
            {
                try
                {
                    Clipboard.SetText(text);
                    break;
                }
                catch
                {
                    Thread.Sleep(25);
                }
            }

            // Wait briefly for user to finish releasing Ctrl / Win / Alt so Ctrl+V does not become Ctrl+Win+V.
            int waited = 0;
            while (waited < 400)
            {
                if (!IsKeyDown(0x11) && !IsKeyDown(0x5B) && !IsKeyDown(0x5C) && !IsKeyDown(0x12))
                {
                    break;
                }
                Thread.Sleep(15);
                waited += 15;
            }
            Thread.Sleep(30);

            SendCtrlV();

            if (restoreClipboard)
            {
                Thread.Sleep(200);
                try
                {
                    if (hadText && prevText != null) Clipboard.SetText(prevText);
                    else Clipboard.Clear();
                }
                catch { }
            }
        }

        private static bool IsKeyDown(int vk)
        {
            return (GetAsyncKeyState(vk) & 0x8000) != 0;
        }

        private static void SendCtrlV()
        {
            INPUT[] inputs = new INPUT[4];
            inputs[0] = MakeKeyInput(0x11, 0);          // VK_CONTROL down
            inputs[1] = MakeKeyInput(0x56, 0);          // 'V' down
            inputs[2] = MakeKeyInput(0x56, 0x0002);     // 'V' up
            inputs[3] = MakeKeyInput(0x11, 0x0002);     // VK_CONTROL up
            SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        }

        private static INPUT MakeKeyInput(ushort vk, uint flags)
        {
            INPUT inp = new INPUT();
            inp.type = 1; // INPUT_KEYBOARD
            inp.u.ki.wVk = vk;
            inp.u.ki.dwFlags = flags;
            return inp;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WAVEINCAPS
        {
            public ushort wMid;
            public ushort wPid;
            public uint vDriverVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string szPname;
            public uint dwFormats;
            public ushort wChannels;
            public ushort wReserved1;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public uint type;
            public InputUnion u;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        private static extern uint waveInGetNumDevs();

        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        private static extern int waveInGetDevCaps(IntPtr uDeviceID, ref WAVEINCAPS pwic, uint cbwic);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    }

    public sealed class WaveRecorder : IDisposable
    {
        private const int SampleRate = 16000;
        private const int BufferCount = 4;
        private const int BufferBytes = 3200; // 100 ms at 16kHz 16-bit mono
        private const uint CALLBACK_FUNCTION = 0x00030000;
        private const int WIM_DATA = 0x3C0;

        private delegate void WaveInProc(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2);

        private IntPtr _hWaveIn = IntPtr.Zero;
        private WaveInProc _callback;
        private readonly object _lock = new object();
        private MemoryStream _pcm = new MemoryStream();
        private byte[][] _buffers;
        private GCHandle[] _bufHandles;
        private WAVEHDR[] _headers;
        private GCHandle[] _hdrHandles;
        private volatile bool _recording;
        private readonly ConcurrentQueue<int> _requeue = new ConcurrentQueue<int>();
        private readonly AutoResetEvent _requeueEvent = new AutoResetEvent(false);
        private Thread _requeueThread;
        private double _peak;

        public bool IsRecording { get { return _recording; } }
        public double PeakLevel { get { return _peak; } }

        public void Start(int deviceIndex)
        {
            if (_recording) return;
            lock (_lock)
            {
                _pcm.Dispose();
                _pcm = new MemoryStream();
                _peak = 0.0;
            }

            WAVEFORMATEX fmt = new WAVEFORMATEX();
            fmt.wFormatTag = 1; // PCM
            fmt.nChannels = 1;
            fmt.nSamplesPerSec = SampleRate;
            fmt.wBitsPerSample = 16;
            fmt.nBlockAlign = 2;
            fmt.nAvgBytesPerSec = SampleRate * 2;
            fmt.cbSize = 0;

            _callback = new WaveInProc(OnWaveInData);
            uint devId = deviceIndex < 0 ? 0xFFFFFFFFu : (uint)deviceIndex;
            int res = waveInOpen(out _hWaveIn, devId, ref fmt, _callback, IntPtr.Zero, CALLBACK_FUNCTION);
            if (res != 0)
            {
                throw new InvalidOperationException("Could not open microphone (waveInOpen error " + res + ").");
            }

            _buffers = new byte[BufferCount][];
            _bufHandles = new GCHandle[BufferCount];
            _headers = new WAVEHDR[BufferCount];
            _hdrHandles = new GCHandle[BufferCount];

            int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
            for (int i = 0; i < BufferCount; i++)
            {
                _buffers[i] = new byte[BufferBytes];
                _bufHandles[i] = GCHandle.Alloc(_buffers[i], GCHandleType.Pinned);
                _headers[i] = new WAVEHDR();
                _headers[i].lpData = _bufHandles[i].AddrOfPinnedObject();
                _headers[i].dwBufferLength = (uint)BufferBytes;
                _headers[i].dwUser = (IntPtr)i;
                _hdrHandles[i] = GCHandle.Alloc(_headers[i], GCHandleType.Pinned);
                waveInPrepareHeader(_hWaveIn, _hdrHandles[i].AddrOfPinnedObject(), (uint)hdrSize);
                waveInAddBuffer(_hWaveIn, _hdrHandles[i].AddrOfPinnedObject(), (uint)hdrSize);
            }

            _recording = true;
            _requeueThread = new Thread(RequeueLoop);
            _requeueThread.IsBackground = true;
            _requeueThread.Start();

            int startRes = waveInStart(_hWaveIn);
            if (startRes != 0)
            {
                StopAndGetPcm16();
                throw new InvalidOperationException("Could not start microphone (waveInStart error " + startRes + ").");
            }
        }

        private void OnWaveInData(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2)
        {
            if (uMsg != WIM_DATA || !_recording || dwParam1 == IntPtr.Zero) return;
            try
            {
                WAVEHDR hdr = (WAVEHDR)Marshal.PtrToStructure(dwParam1, typeof(WAVEHDR));
                int idx = (int)hdr.dwUser;
                int recorded = (int)hdr.dwBytesRecorded;
                if (recorded > 0 && idx >= 0 && idx < BufferCount)
                {
                    byte[] chunk = new byte[recorded];
                    Marshal.Copy(hdr.lpData, chunk, 0, recorded);
                    double localPeak = 0.0;
                    for (int i = 0; i + 1 < recorded; i += 2)
                    {
                        short s = (short)(chunk[i] | (chunk[i + 1] << 8));
                        double v = Math.Abs(s / 32768.0);
                        if (v > localPeak) localPeak = v;
                    }
                    lock (_lock)
                    {
                        _pcm.Write(chunk, 0, recorded);
                        if (localPeak > _peak) _peak = localPeak;
                    }
                }
                if (_recording)
                {
                    _requeue.Enqueue(idx);
                    _requeueEvent.Set();
                }
            }
            catch { }
        }

        private void RequeueLoop()
        {
            int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
            while (_recording)
            {
                _requeueEvent.WaitOne(100);
                int idx;
                while (_recording && _requeue.TryDequeue(out idx))
                {
                    try
                    {
                        if (_hWaveIn != IntPtr.Zero && _hdrHandles != null && idx >= 0 && idx < _hdrHandles.Length)
                        {
                            waveInAddBuffer(_hWaveIn, _hdrHandles[idx].AddrOfPinnedObject(), (uint)hdrSize);
                        }
                    }
                    catch { }
                }
            }
        }

        public byte[] StopAndGetPcm16()
        {
            _recording = false;
            _requeueEvent.Set();
            if (_requeueThread != null)
            {
                try { _requeueThread.Join(400); } catch { }
                _requeueThread = null;
            }
            if (_hWaveIn != IntPtr.Zero)
            {
                try { waveInStop(_hWaveIn); } catch { }
                try { waveInReset(_hWaveIn); } catch { }
                int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
                if (_hdrHandles != null)
                {
                    for (int i = 0; i < _hdrHandles.Length; i++)
                    {
                        if (_hdrHandles[i].IsAllocated)
                        {
                            try { waveInUnprepareHeader(_hWaveIn, _hdrHandles[i].AddrOfPinnedObject(), (uint)hdrSize); } catch { }
                            _hdrHandles[i].Free();
                        }
                        if (_bufHandles != null && _bufHandles[i].IsAllocated)
                        {
                            _bufHandles[i].Free();
                        }
                    }
                }
                try { waveInClose(_hWaveIn); } catch { }
                _hWaveIn = IntPtr.Zero;
            }
            lock (_lock)
            {
                return _pcm.ToArray();
            }
        }

        public static byte[] WrapWav(byte[] pcm16)
        {
            using (MemoryStream ms = new MemoryStream(44 + pcm16.Length))
            using (BinaryWriter bw = new BinaryWriter(ms))
            {
                bw.Write(Encoding.ASCII.GetBytes("RIFF"));
                bw.Write(36 + pcm16.Length);
                bw.Write(Encoding.ASCII.GetBytes("WAVE"));
                bw.Write(Encoding.ASCII.GetBytes("fmt "));
                bw.Write(16);
                bw.Write((short)1);
                bw.Write((short)1);
                bw.Write(SampleRate);
                bw.Write(SampleRate * 2);
                bw.Write((short)2);
                bw.Write((short)16);
                bw.Write(Encoding.ASCII.GetBytes("data"));
                bw.Write(pcm16.Length);
                bw.Write(pcm16);
                return ms.ToArray();
            }
        }

        public void Dispose()
        {
            StopAndGetPcm16();
            lock (_lock) { _pcm.Dispose(); }
            _requeueEvent.Dispose();
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WAVEFORMATEX
        {
            public ushort wFormatTag;
            public ushort nChannels;
            public uint nSamplesPerSec;
            public uint nAvgBytesPerSec;
            public ushort nBlockAlign;
            public ushort wBitsPerSample;
            public ushort cbSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WAVEHDR
        {
            public IntPtr lpData;
            public uint dwBufferLength;
            public uint dwBytesRecorded;
            public IntPtr dwUser;
            public uint dwFlags;
            public uint dwLoops;
            public IntPtr lpNext;
            public IntPtr reserved;
        }

        [DllImport("winmm.dll")]
        private static extern int waveInOpen(out IntPtr phwi, uint uDeviceID, ref WAVEFORMATEX pwfx, WaveInProc dwCallback, IntPtr dwInstance, uint fdwOpen);
        [DllImport("winmm.dll")]
        private static extern int waveInPrepareHeader(IntPtr hwi, IntPtr pwh, uint cbwh);
        [DllImport("winmm.dll")]
        private static extern int waveInUnprepareHeader(IntPtr hwi, IntPtr pwh, uint cbwh);
        [DllImport("winmm.dll")]
        private static extern int waveInAddBuffer(IntPtr hwi, IntPtr pwh, uint cbwh);
        [DllImport("winmm.dll")]
        private static extern int waveInStart(IntPtr hwi);
        [DllImport("winmm.dll")]
        private static extern int waveInStop(IntPtr hwi);
        [DllImport("winmm.dll")]
        private static extern int waveInReset(IntPtr hwi);
        [DllImport("winmm.dll")]
        private static extern int waveInClose(IntPtr hwi);
    }

    public sealed class KeyboardHook : IDisposable
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_SYSKEYUP = 0x0105;

        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        private IntPtr _hookId = IntPtr.Zero;
        private LowLevelKeyboardProc _proc;
        private readonly HashSet<string> _triggerTokens = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<string> _downTokens = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private bool _active;
        private bool _cancelled;
        public readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();

        public void SetHotkey(string spec)
        {
            _triggerTokens.Clear();
            if (string.IsNullOrEmpty(spec)) spec = "ctrl+win";
            string[] parts = spec.Split('+');
            for (int i = 0; i < parts.Length; i++)
            {
                string t = parts[i].Trim().ToLowerInvariant();
                if (!string.IsNullOrEmpty(t)) _triggerTokens.Add(t);
            }
            if (_triggerTokens.Count == 0)
            {
                _triggerTokens.Add("ctrl");
                _triggerTokens.Add("win");
            }
        }

        public void Install(string hotkeySpec)
        {
            SetHotkey(hotkeySpec);
            _proc = new LowLevelKeyboardProc(HookCallback);
            using (Process cur = Process.GetCurrentProcess())
            using (ProcessModule mod = cur.MainModule)
            {
                _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(mod.ModuleName), 0);
            }
        }

        private static string TokenForVk(int vk)
        {
            if (vk == 0x11 || vk == 0xA2 || vk == 0xA3) return "ctrl";
            if (vk == 0x5B || vk == 0x5C) return "win";
            if (vk == 0x12 || vk == 0xA4 || vk == 0xA5) return "alt";
            if (vk == 0x10 || vk == 0xA0 || vk == 0xA1) return "shift";
            if (vk == 0x20) return "space";
            if (vk == 0x14) return "caps_lock";
            if (vk == 0x91) return "scroll_lock";
            if (vk == 0x13) return "pause";
            if (vk == 0x2D) return "insert";
            if (vk >= 0x70 && vk <= 0x87) return "f" + (vk - 0x70 + 1);
            if ((vk >= 0x41 && vk <= 0x5A) || (vk >= 0x30 && vk <= 0x39)) return ((char)vk).ToString().ToLowerInvariant();
            return "vk_" + vk;
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                KBDLLHOOKSTRUCT info = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                if ((info.flags & 0x10) == 0) // ignore injected keys
                {
                    int msg = wParam.ToInt32();
                    string tok = TokenForVk((int)info.vkCode);
                    if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN)
                    {
                        _downTokens.Add(tok);
                        if (_active)
                        {
                            if (!_triggerTokens.Contains(tok))
                            {
                                _active = false;
                                _cancelled = true;
                                Events.Enqueue("cancel");
                            }
                        }
                        else if (!_cancelled && _downTokens.Count == _triggerTokens.Count && _downTokens.IsSupersetOf(_triggerTokens))
                        {
                            _active = true;
                            Events.Enqueue("start");
                        }
                    }
                    else if (msg == WM_KEYUP || msg == WM_SYSKEYUP)
                    {
                        _downTokens.Remove(tok);
                        if (_active && _triggerTokens.Contains(tok))
                        {
                            _active = false;
                            Events.Enqueue("stop");
                        }
                        if (_cancelled && !_downTokens.Overlaps(_triggerTokens))
                        {
                            _cancelled = false;
                        }
                    }
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }

        public void Dispose()
        {
            if (_hookId != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_hookId);
                _hookId = IntPtr.Zero;
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT
        {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);
    }

    public sealed class PillForm : Form
    {
        private string _state = "hidden";
        private string _text = "";
        private readonly Color _bg = Color.FromArgb(22, 27, 36);
        private readonly Color _border = Color.FromArgb(56, 189, 248);

        public PillForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            DoubleBuffered = true;
            BackColor = Color.Magenta;
            TransparencyKey = Color.Magenta;
            Size = new Size(260, 42);
            PositionPill();
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000020 | 0x00000008; // NOACTIVATE | TOOLWINDOW | TRANSPARENT | TOPMOST
                return cp;
            }
        }

        public void UpdateState(string state, string text)
        {
            _state = state ?? "hidden";
            _text = text ?? "";
            if (_state == "hidden")
            {
                if (Visible) Hide();
                return;
            }
            PositionPill();
            if (!Visible) Show();
            Invalidate();
        }

        private void PositionPill()
        {
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            int w = Math.Min(420, Math.Max(200, _text.Length * 8 + 70));
            Size = new Size(w, 40);
            Location = new Point(wa.Left + (wa.Width - w) / 2, wa.Bottom - 62);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(1, 1, Width - 3, Height - 3);
            using (GraphicsPath path = RoundedRect(rect, 18))
            using (SolidBrush bg = new SolidBrush(_bg))
            using (Pen pen = new Pen(_state == "recording" ? Color.FromArgb(248, 113, 113) : _border, 1.5f))
            {
                g.FillPath(bg, path);
                g.DrawPath(pen, path);
            }
            Color dotColor = _state == "recording" ? Color.FromArgb(248, 113, 113)
                           : _state == "processing" ? Color.FromArgb(251, 191, 36)
                           : Color.FromArgb(52, 211, 153);
            using (SolidBrush db = new SolidBrush(dotColor))
            {
                g.FillEllipse(db, 14, (Height - 10) / 2, 10, 10);
            }
            using (Font f = new Font("Segoe UI", 9.5f, FontStyle.Regular))
            using (SolidBrush tb = new SolidBrush(Color.FromArgb(230, 237, 246)))
            {
                StringFormat sf = new StringFormat();
                sf.LineAlignment = StringAlignment.Center;
                sf.Trimming = StringTrimming.EllipsisCharacter;
                g.DrawString(_text, f, tb, new RectangleF(32, 0, Width - 42, Height), sf);
            }
        }

        private static GraphicsPath RoundedRect(Rectangle r, int radius)
        {
            int d = radius * 2;
            GraphicsPath gp = new GraphicsPath();
            gp.AddArc(r.X, r.Y, d, d, 180, 90);
            gp.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            gp.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            gp.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            gp.CloseFigure();
            return gp;
        }
    }
}
