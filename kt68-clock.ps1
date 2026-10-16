$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class Kt68Clock {
    const int Width = 65;
    const int Height = 5;
    const int Leds = Width * Height;
    const int FrameBytes = 1024;
    const int ReportSize = 65;
    const ushort Vendor = 0x05AC;
    const ushort Product = 0x024F;
    const ushort UsagePage = 0xFF13;
    const uint DigcfPresent = 0x02;
    const uint DigcfDeviceInterface = 0x10;
    const uint GenericRead = 0x80000000;
    const uint GenericWrite = 0x40000000;
    const uint FileShareRead = 0x01;
    const uint FileShareWrite = 0x02;
    const uint OpenExisting = 3;
    const int HidpStatusSuccess = 0x00110000;
    static readonly IntPtr InvalidHandle = new IntPtr(-1);

    static readonly Dictionary<char, string[]> Glyphs = new Dictionary<char, string[]> {
        { '0', new[] { "###", "# #", "# #", "# #", "###" } },
        { '1', new[] { ".#.", "##.", ".#.", ".#.", "###" } },
        { '2', new[] { "###", "..#", "###", "#..", "###" } },
        { '3', new[] { "###", "..#", "###", "..#", "###" } },
        { '4', new[] { "#.#", "#.#", "###", "..#", "..#" } },
        { '5', new[] { "###", "#..", "###", "..#", "###" } },
        { '6', new[] { "###", "#..", "###", "#.#", "###" } },
        { '7', new[] { "###", "..#", "..#", "..#", "..#" } },
        { '8', new[] { "###", "#.#", "###", "#.#", "###" } },
        { '9', new[] { "###", "#.#", "###", "..#", "###" } },
        { '/', new[] { "..#", ".#.", ".#.", "#..", "#.." } },
        { ':', new[] { ".", "#", ".", "#", "." } },
        { ' ', new[] { " ", " ", " ", " ", " " } }
    };

    [StructLayout(LayoutKind.Sequential)]
    struct HIDD_ATTRIBUTES {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [DllImport("hid.dll")]
    static extern void HidD_GetHidGuid(out Guid hidGuid);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_GetAttributes(IntPtr handle, ref HIDD_ATTRIBUTES attributes);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_GetPreparsedData(IntPtr handle, out IntPtr preparsed);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_FreePreparsedData(IntPtr preparsed);

    [DllImport("hid.dll", SetLastError = true)]
    static extern int HidP_GetCaps(IntPtr preparsed, ref HIDP_CAPS caps);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_SetFeature(IntPtr handle, byte[] buffer, int length);

    [DllImport("hid.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool HidD_GetProductString(IntPtr handle, byte[] buffer, int length);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, string enumerator, IntPtr parent, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr deviceInfoSet, IntPtr deviceInfoData, ref Guid interfaceClassGuid, uint memberIndex, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr deviceInfoSet, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData, IntPtr deviceInterfaceDetailData, uint deviceInterfaceDetailDataSize, out uint requiredSize, IntPtr deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    public static void Run() {
        IntPtr handle = InvalidHandle;
        string shown = null;
        while (true) {
            if (handle == InvalidHandle || handle == IntPtr.Zero) {
                handle = Open();
                if (handle == InvalidHandle || handle == IntPtr.Zero) {
                    System.Threading.Thread.Sleep(1000);
                    continue;
                }
                Console.WriteLine("keyboard connected");
            }
            DateTime moment = DateTime.Now;
            if (!ShowFrame(handle, Pixels(moment))) {
                CloseHandle(handle);
                handle = InvalidHandle;
                Console.WriteLine("keyboard disconnected, waiting");
                System.Threading.Thread.Sleep(1000);
                continue;
            }
            string label = moment.ToString("dd/MM HH:mm:ss");
            if (label != shown) {
                Console.WriteLine(label);
                shown = label;
            }
            System.Threading.Thread.Sleep(50);
        }
    }

    static IntPtr Open() {
        Guid hidGuid;
        HidD_GetHidGuid(out hidGuid);
        IntPtr list = SetupDiGetClassDevs(ref hidGuid, null, IntPtr.Zero, DigcfPresent | DigcfDeviceInterface);
        if (list == InvalidHandle || list == IntPtr.Zero) {
            return InvalidHandle;
        }
        try {
            uint index = 0;
            while (true) {
                SP_DEVICE_INTERFACE_DATA data = new SP_DEVICE_INTERFACE_DATA();
                data.cbSize = Marshal.SizeOf(data);
                if (!SetupDiEnumDeviceInterfaces(list, IntPtr.Zero, ref hidGuid, index, ref data)) {
                    break;
                }
                index++;
                uint required;
                SetupDiGetDeviceInterfaceDetail(list, ref data, IntPtr.Zero, 0, out required, IntPtr.Zero);
                if (required < 8) {
                    continue;
                }
                IntPtr detail = Marshal.AllocHGlobal((int)required);
                try {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(list, ref data, detail, required, out required, IntPtr.Zero)) {
                        continue;
                    }
                    string path = Marshal.PtrToStringUni(new IntPtr(detail.ToInt64() + 4));
                    IntPtr handle = TryOpen(path);
                    if (handle != InvalidHandle && handle != IntPtr.Zero) {
                        return handle;
                    }
                } finally {
                    Marshal.FreeHGlobal(detail);
                }
            }
        } finally {
            SetupDiDestroyDeviceInfoList(list);
        }
        return InvalidHandle;
    }

    static IntPtr TryOpen(string path) {
        IntPtr handle = CreateFile(path, GenericRead | GenericWrite, FileShareRead | FileShareWrite, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
        if (handle == InvalidHandle || handle == IntPtr.Zero) {
            return InvalidHandle;
        }
        HIDD_ATTRIBUTES attributes = new HIDD_ATTRIBUTES();
        attributes.Size = Marshal.SizeOf(attributes);
        if (!HidD_GetAttributes(handle, ref attributes) || attributes.VendorID != Vendor || attributes.ProductID != Product) {
            CloseHandle(handle);
            return InvalidHandle;
        }
        IntPtr preparsed;
        if (!HidD_GetPreparsedData(handle, out preparsed)) {
            CloseHandle(handle);
            return InvalidHandle;
        }
        HIDP_CAPS caps = new HIDP_CAPS();
        caps.Reserved = new ushort[17];
        int status = HidP_GetCaps(preparsed, ref caps);
        HidD_FreePreparsedData(preparsed);
        if (status != HidpStatusSuccess || caps.UsagePage != UsagePage) {
            CloseHandle(handle);
            return InvalidHandle;
        }
        byte[] product = new byte[254];
        if (HidD_GetProductString(handle, product, product.Length)) {
            string name = System.Text.Encoding.Unicode.GetString(product).TrimEnd('\0');
            if (name.IndexOf("KT68", StringComparison.OrdinalIgnoreCase) < 0) {
                CloseHandle(handle);
                return InvalidHandle;
            }
        }
        return handle;
    }

    static bool Feature(IntPtr handle, byte[] payload, int pauseMs) {
        byte[] buffer = new byte[ReportSize];
        Buffer.BlockCopy(payload, 0, buffer, 1, Math.Min(payload.Length, 64));
        if (!HidD_SetFeature(handle, buffer, buffer.Length)) {
            return false;
        }
        System.Threading.Thread.Sleep(pauseMs);
        return true;
    }

    static byte[] Pixels(DateTime moment) {
        string text = moment.ToString("dd/MM HH:mm:ss");
        int used = 0;
        foreach (char character in text) {
            used += Glyphs[character][0].Length;
        }
        used += text.Length - 1;
        int x = Math.Max(0, (Width - used) / 2);
        byte[] blob = new byte[FrameBytes];
        foreach (char character in text) {
            string[] glyph = Glyphs[character];
            for (int y = 0; y < glyph.Length; y++) {
                string row = glyph[y];
                for (int column = 0; column < row.Length; column++) {
                    if (row[column] == '#' && x + column < Width) {
                        int led = (y * Width) + x + column;
                        int offset = led * 3;
                        blob[offset] = 255;
                        blob[offset + 1] = 255;
                        blob[offset + 2] = 255;
                    }
                }
            }
            x += glyph[0].Length + 1;
        }
        blob[976] = 0xAA;
        blob[977] = 0x55;
        return blob;
    }

    static bool ShowFrame(IntPtr handle, byte[] blob) {
        if (!Feature(handle, new byte[] { 0x04, 0x18 }, 15)) {
            return false;
        }
        byte[] preamble = new byte[64];
        preamble[0] = 0x04;
        preamble[1] = 0x35;
        preamble[8] = 0x10;
        if (!Feature(handle, preamble, 15)) {
            return false;
        }
        for (int offset = 0; offset < FrameBytes; offset += 64) {
            byte[] chunk = new byte[64];
            Buffer.BlockCopy(blob, offset, chunk, 0, 64);
            if (!Feature(handle, chunk, 2)) {
                return false;
            }
        }
        return Feature(handle, new byte[] { 0x04, 0x02 }, 15);
    }
}
"@

[Kt68Clock]::Run()
