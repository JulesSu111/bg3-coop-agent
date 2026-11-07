"""Native Windows lifetime controls, without a resident CLR/PowerShell host."""
import ctypes
from ctypes import wintypes
import hashlib
import os


class LauncherLifetime:
    def __init__(self, root):
        if os.name != "nt":
            raise OSError("Windows supervisor required")
        self.api = api = ctypes.WinDLL("kernel32", use_last_error=True)
        api.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        api.CreateMutexW.restype = wintypes.HANDLE
        api.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        api.CreateJobObjectW.restype = wintypes.HANDLE
        api.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        api.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        api.GetCurrentProcess.restype = wintypes.HANDLE
        api.CloseHandle.argtypes = [wintypes.HANDLE]
        name = "Local\\BG3Coop-" + hashlib.sha256(str(root.resolve()).lower().encode()).hexdigest()[:32]
        self.mutex = api.CreateMutexW(None, True, name)
        if not self.mutex:
            raise ctypes.WinError(ctypes.get_last_error())
        self.duplicate = ctypes.get_last_error() == 183
        self.job = None
        if self.duplicate:
            api.CloseHandle(self.mutex)
            return

        class Basic(ctypes.Structure):
            _fields_ = [("ProcessTime", ctypes.c_int64), ("JobTime", ctypes.c_int64),
                        ("LimitFlags", wintypes.DWORD), ("MinWorkingSet", ctypes.c_size_t),
                        ("MaxWorkingSet", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t), ("Priority", wintypes.DWORD), ("Scheduling", wintypes.DWORD)]
        class Extended(ctypes.Structure):
            _fields_ = [("Basic", Basic), ("Io", ctypes.c_uint64 * 6),
                        ("ProcessMemory", ctypes.c_size_t), ("JobMemory", ctypes.c_size_t),
                        ("PeakProcessMemory", ctypes.c_size_t), ("PeakJobMemory", ctypes.c_size_t)]
        job = api.CreateJobObjectW(None, None)
        if not job:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = Extended()
        limits.Basic.LimitFlags = 0x2000  # KILL_ON_JOB_CLOSE; no breakaway allowed
        if not api.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.get_last_error()
            api.CloseHandle(job)
            raise ctypes.WinError(error)
        if not api.AssignProcessToJobObject(job, api.GetCurrentProcess()):
            error = ctypes.get_last_error()
            api.CloseHandle(job)
            raise ctypes.WinError(error)
        # Hold until process exit. The OS closes the exclusive handle and kills descendants.
        self.job = job
