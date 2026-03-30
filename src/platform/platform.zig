const builtin = @import("builtin");

const impl = if (builtin.os.tag == .macos)
    @import("darwin.zig")
else
    @import("linux.zig");

pub const getOsName = impl.getOsName;
pub const getFontDir = impl.getFontDir;
pub const installPackage = impl.installPackage;
pub const postFontInstall = impl.postFontInstall;
