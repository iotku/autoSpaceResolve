-- This isn't a virus, Windows is just this bad at handling processes
-- This code is a Lua FFI wrapper for Windows API functions to create a process and capture its output.
-- without this code, each process would be created in a new window and flash a terminal in the foreground
-- while taking focus away from the user's current window.
local ffi = require("ffi")

ffi.cdef[[
typedef void* HANDLE;
typedef const char* LPCSTR;
typedef unsigned long DWORD;
typedef int BOOL;
typedef void* LPVOID;

typedef struct {
  DWORD nLength;
  void* lpSecurityDescriptor;
  BOOL bInheritHandle;
} SECURITY_ATTRIBUTES;

typedef struct {
  DWORD cb;
  const char* lpReserved;
  const char* lpDesktop;
  const char* lpTitle;
  DWORD dwX, dwY, dwXSize, dwYSize;
  DWORD dwXCountChars, dwYCountChars;
  DWORD dwFillAttribute;
  DWORD dwFlags;
  short wShowWindow;
  short cbReserved2;
  LPVOID lpReserved2;
  HANDLE hStdInput;
  HANDLE hStdOutput;
  HANDLE hStdError;
} STARTUPINFOA;

typedef struct {
  HANDLE hProcess;
  HANDLE hThread;
  DWORD dwProcessId;
  DWORD dwThreadId;
} PROCESS_INFORMATION;

BOOL CreatePipe(HANDLE* hReadPipe, HANDLE* hWritePipe, SECURITY_ATTRIBUTES* lpPipeAttributes, DWORD nSize);
BOOL SetHandleInformation(HANDLE hObject, DWORD dwMask, DWORD dwFlags);
BOOL CreateProcessA(
  LPCSTR lpApplicationName,
  char* lpCommandLine,
  SECURITY_ATTRIBUTES* lpProcessAttributes,
  SECURITY_ATTRIBUTES* lpThreadAttributes,
  BOOL bInheritHandles,
  DWORD dwCreationFlags,
  LPVOID lpEnvironment,
  LPCSTR lpCurrentDirectory,
  STARTUPINFOA* lpStartupInfo,
  PROCESS_INFORMATION* lpProcessInformation
);
BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, void* lpOverlapped);
DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
BOOL CloseHandle(HANDLE hObject);
]]

local function run_command_capture_output(cmd)
  local stdout_read = ffi.new("HANDLE[1]")
  local stdout_write = ffi.new("HANDLE[1]")

  -- Make handles inheritable
  local sa = ffi.new("SECURITY_ATTRIBUTES")
  sa.nLength = ffi.sizeof(sa)
  sa.bInheritHandle = 1
  sa.lpSecurityDescriptor = nil

  assert(ffi.C.CreatePipe(stdout_read, stdout_write, sa, 0) ~= 0, "CreatePipe failed")
  ffi.C.SetHandleInformation(stdout_read[0], 1, 0) -- Don't let child inherit read handle

  local si = ffi.new("STARTUPINFOA")
  si.cb = ffi.sizeof(si)
  si.dwFlags = 0x00000100 -- STARTF_USESTDHANDLES
  si.hStdOutput = stdout_write[0]
  si.hStdError  = stdout_write[0]
  si.hStdInput  = nil

  local pi = ffi.new("PROCESS_INFORMATION")
  local CREATE_NO_WINDOW = 0x08000000

  local cmdline = ffi.new("char[?]", #cmd + 1, cmd)

  local success = ffi.C.CreateProcessA(
    nil, cmdline,
    nil, nil,
    true,
    CREATE_NO_WINDOW,
    nil, nil,
    si, pi
  )

  assert(success ~= 0, "CreateProcess failed")

  ffi.C.CloseHandle(stdout_write[0]) -- Close write-end in parent

  -- Wait for child process to finish
  ffi.C.WaitForSingleObject(pi.hProcess, 10000)

  -- Read the output
  local output = {}
  local buffer = ffi.new("char[4096]")
  local bytesRead = ffi.new("DWORD[1]")

  while ffi.C.ReadFile(stdout_read[0], buffer, 4096, bytesRead, nil) ~= 0 and bytesRead[0] > 0 do
    table.insert(output, ffi.string(buffer, bytesRead[0]))
  end

  ffi.C.CloseHandle(stdout_read[0])
  ffi.C.CloseHandle(pi.hProcess)
  ffi.C.CloseHandle(pi.hThread)

  return table.concat(output)
end

return {
  run_command_capture_output = run_command_capture_output
}