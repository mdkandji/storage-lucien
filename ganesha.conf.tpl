# NFS-Ganesha export of the GlusterFS volume, via FSAL_GLUSTER (libgfapi) --
# direct access to the volume, not a re-export of the local FUSE mount.
# (FSAL_VFS would have been the other option, but the Debian nfs-ganesha
# package only ships libfsalgluster.so, not a VFS FSAL module -- confirmed
# at runtime, "Name = VFS" fails config validation with no such library.
# FSAL_GLUSTER is the natural pairing with GlusterFS anyway.)
NFS_CORE_PARAM {
    Enable_NLM = false;
    Enable_RQUOTA = false;
    mount_path_pseudo = true;
    Protocols = 4;
}

NFSv4 {
    Grace_Period = 5;
    Lease_Lifetime = 5;
    Minor_Versions = 1,2;
}

EXPORT {
    Export_Id = 1;
    Path = "/";
    Pseudo = /mail;
    Access_Type = RW;
    Squash = No_root_squash;
    SecType = sys;
    Protocols = 4;
    Transports = TCP;

    FSAL {
        Name = GLUSTER;
        Hostname = "localhost";
        Volume = "${GLUSTER_VOL}";
    }
}

LOG {
    Default_Log_Level = EVENT;
}
