# README for compiling LAME with Visual Studio 2019

This document describes how to compile the LAME projects using Visual Studio
2019. Any edition will do, even the free Community edition. Be sure to install
the "Desktop development with C++" workload.

## Projects

There are two solution files in the "lame/vc_solution" folder that can be
opened. The solution "vs2019_lame.sln" contains the following projects:

- lame: The lame.exe command line executable
- libmp3lame: The dynamic library libmp3lame.dll
- libmp3lame-static: The static library variant of the above
- mp3rtp: command line tool to stream mp3 via RTP protocol
- mp3x: mp3 frame analyzer tool using GTK1 (see below)

The solution "vs2019_lame_clients.sln" contains several more projects:

- ACM, ADbg, tinyxml: Ancient Windows "Audio Codec Manager"
- lame_DirectShow: DirectShow filter
- lame_test: Test program

In the two solutions there are several configurations that can be used to
compile different flavors of LAME libraries and executables:

- Debug: Builds without optimization, but debugging support
- Release: Optimization build, without SSE2 or NASM assembly
- ReleaseNASM: Uses NASM (see below) to compile some routines using NASM
- ReleaseSSE2: Uses SSE2 assembler instructions to optimize routines

The vs2019_lame.sln solution has both Win32 and x64 platforms configured, in
order to compile lame.exe and the libmp3lame.dll for 32-bit or 64-bit target
platforms. The output folder also has separate folders for the two platforms.
Note that mp3rtp and mp3x are not compiled in x64. Also note that all 64-bit
processors have SSE2 instructions, so the /arch:SSE2 option is ignored for
this platform.

## External libraries and tools

For some projects, external libraries or tools are necessary for successful
compilation. These can be configured using .props files or the Property Manager
window of Visual Studio (View > Other Windows > Property Manager). The props
files have a "User Macros" page where the variable values can be changed.

### NASM

The Netwide Assembler is used to compile assembly routines contained in the
.nas files. The most recent version of NASM can be downloaded here:
https://nasm.us/

Extract the zip archive in any folder. Open the file
"lame/vc_solution/vs2019_arch_nasm.props" and edit the `NasmPath` in the first
few lines of the file, ending the path with a backslash. As described above,
you can also use the Property Manager view to change the values.

Note that NASM is only used when selecting the "ReleaseNASM" configuration.

### libsndfile

LAME can be compiled with the libsndfile library for audio input. Libsndfile
can be downloaded here:
http://mega-nerd.com/libsndfile/#Download

Install the Win32 installer into any folder, or (if available) extract
pre-release versions (e.g. libsndfile-1.0.29pre1-w32.zip) into any folder.

Open the file "lame/vc_solution/vs2019_lame_config.props" and edit the
following  two user macro parameters:

- The value of `HaveLibsndfile` can be set to false or true, and specifies if
  the libsndfile library is available and used in lame.exe
- `LibsndfilePath` specifies the path to the root folder of libsndfile, ending
  the path with a backslash. The folder should contain the `include`, `lib`
  and `bin` folders.

As described above, you can also use the Property Manager view to change the
values.

Note that when compiling for the x64 platform, you have to use the 64-bit
version of libsndfile. Alternatively you can use the `HaveLibsndfile` as is
(the default value is `.\libsndfile\$(Platform)\`) and extract the zip
archives for 32-bit and 64-bit into the "vc_solution\libsndfile\Win32\" and
"vc_solution\libsndfile\x64\" folders.

### mpg123

From LAME version 3.100.1 on, LAME supports decoding using the external mpg123
library, which is a mature fork of the internally used mpglib library. The
latest binaries for Win32 and x64 are available here:
https://mpg123.de/

Open the file "lame/vc_solution/vs2019_libmpg123_config.props" and edit the
following  two user macro parameters:

- The value of `HaveMpg123` can be set to false or true, and specifies if
  the libmpg123 library is available and used in lame.exe and libmp3lame.dll.
  When set to false, decoding is not available in LAME. This includes
  calculating accurate Replaygain by decoding the just encoded data on-the-fly.
- `Mpg123Path` specifies the path to the root folder of mpg123, ending
  the path with a backslash. The folder should contain the `mpg123.h` and
  `libmpg123-0.dll` files, among others.

As described above, you can also use the Property Manager view to change the
values.

Note that when compiling for the x64 platform, you have to use the 64-bit
version of libmpg123. Alternatively you can use the `HaveMpg123` as is
(the default value is `.\mpg123\$(Platform)\`) and extract the zip
archives for 32-bit and 64-bit into the "vc_solution\mpg123\Win32\" and
"vc_solution\mpg123\x64\" folders.

### GTK1

The mp3x graphical frame analyzer uses GTK1 for the user interface. One of the
few still available ports to Windows is "GTK1 for Windows", which can be used
to compile mp3x. You can download version 1.4 here:
https://sourceforge.net/projects/gtk1-win/

Extract the zip archive in any folder. Open the file
"lame/vc_solution/vs2019_gtk_config.props" and edit the `WinGtkPath` in the
first few lines of the file, ending the path with a backslash.

As described above, you can also use the Property Manager view to change the
values.

Note that compiling mp3x for 64-bit platforms is currently not available.

### Windows SDK 7.1

For the DirectShow filter, the Windows SDK 7.1 is needed, especially the
samples folder where a multimedia base class library must be compiled before.

Download the Windows SDK 7.1 installer from here:
https://www.microsoft.com/en-us/download/details.aspx?id=8279
(or search for "Microsoft Windows SDK for Windows 7 and .NET Framework 4",
version 7.1)

When starting the web setup, you can choose the installation options. Only the
"Samples" under "Windows Native Code Development" is actually necessary.

Open the file "lame/vc_solution/vs2019_win71sdk_config.props" and edit the
`Win71SdkPath` in the first few lines of the file, ending the path with a
backslash. As described above, you can also use the Property Manager view to
change the values.

In the Win71SdkPath path, locate the solution file
"Samples\multimedia\directshow\baseclasses\baseclasses.sln", convert it from
the old Visual Studio project format and compile the "Debug_MBCS" and
"Release_MBCS" configurations. The resulting files strmbasd.lib and
strmbase.lib are used by the lame_DirectShow project for linking.
