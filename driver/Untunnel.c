// The Untunnel audio server plug-in.
//
// Two devices share one clock and one ring: the hidden "Untunnel Feed" output, which the app
// writes with an ordinary IOProc, and the visible "Untunnel Microphone" input other apps read.
// No memory is shared with the app, so nothing crosses coreaudiod's sandbox.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>

#include "UntunnelDriverCore.h"

#ifndef UNTUNNEL_DRIVER_VERSION
#error "UNTUNNEL_DRIVER_VERSION must be defined by the build"
#endif

#ifndef UNTUNNEL_LIVENESS_BY_CLIENTS
#define UNTUNNEL_LIVENESS_BY_CLIENTS 0
#endif

enum {
    kObjectID_Microphone = 2,
    kObjectID_MicrophoneStream = 3,
    kObjectID_Feed = 4,
    kObjectID_FeedStream = 5,
};

enum {
    kSelector_Heartbeat = 'hbt ',
    kSelector_Version = 'vers',
};

#define kManufacturer CFSTR("Intesar Jawad")
#define kMicrophoneName CFSTR("Untunnel Microphone")
#define kFeedName CFSTR("Untunnel Feed")
#define kMicrophoneUID CFSTR("com.intesarjawad.untunnel.microphone")
#define kFeedUID CFSTR("com.intesarjawad.untunnel.feed")
#define kModelUID CFSTR("com.intesarjawad.untunnel.model")

static const Float64 kSampleRate = 48000;
static const UInt32 kClockDomain = 0x48694d63;
static const UInt32 kRingFrames = 16384;
static const UInt64 kLivenessTimeoutNanoseconds = 2000000000ull;
static const UInt64 kLivenessPollNanoseconds = 250000000ull;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;

static float gRingStorage[16384 * UNTUNNEL_RING_CHANNELS];
static untunnel_ring gRing;
static untunnel_clock gClock;
static untunnel_liveness gLiveness;
static dispatch_source_t gLivenessTimer = NULL;

static UInt32 gClockRunning = 0;
static UInt32 gMicrophoneRunning = 0;
static UInt32 gFeedRunning = 0;
static _Atomic UInt32 gMicrophoneChannels = 2;
static _Atomic UInt32 gFeedChannels = 2;

static UInt64 NowNanoseconds(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static Boolean IsDevice(AudioObjectID object) {
    return object == kObjectID_Microphone || object == kObjectID_Feed;
}

static Boolean IsStream(AudioObjectID object) {
    return object == kObjectID_MicrophoneStream || object == kObjectID_FeedStream;
}

static AudioObjectID StreamOf(AudioObjectID device) {
    return device == kObjectID_Microphone ? kObjectID_MicrophoneStream : kObjectID_FeedStream;
}

static AudioObjectID DeviceOf(AudioObjectID stream) {
    return stream == kObjectID_MicrophoneStream ? kObjectID_Microphone : kObjectID_Feed;
}

static _Atomic UInt32 *ChannelsOf(AudioObjectID device) {
    return device == kObjectID_Microphone ? &gMicrophoneChannels : &gFeedChannels;
}

static AudioStreamBasicDescription Format(UInt32 channels) {
    AudioStreamBasicDescription format = {
        .mSampleRate = kSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = (UInt32)sizeof(Float32) * channels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = (UInt32)sizeof(Float32) * channels,
        .mChannelsPerFrame = channels,
        .mBitsPerChannel = 32,
    };
    return format;
}

static Boolean MicrophoneVisible(void) {
    pthread_mutex_lock(&gStateMutex);
    Boolean visible = gLiveness.visible;
    pthread_mutex_unlock(&gStateMutex);
    return visible;
}

static UInt32 DeviceList(AudioObjectID *devices, UInt32 capacity) {
    AudioObjectID all[2] = {kObjectID_Microphone, kObjectID_Feed};
    Boolean visible = MicrophoneVisible();
    UInt32 count = 0;
    for (UInt32 index = 0; index < 2 && count < capacity; index++) {
        if (all[index] == kObjectID_Microphone && !visible) {
            continue;
        }
        devices[count++] = all[index];
    }
    return count;
}

static void NotifyDeviceListChanged(void) {
    if (gHost == NULL) {
        return;
    }
    AudioObjectPropertyAddress addresses[2] = {
        {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal,
         kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal,
         kAudioObjectPropertyElementMain},
    };
    gHost->PropertiesChanged(gHost, kAudioObjectPlugInObject, 2, addresses);
}

static void UpdateLiveness(void) {
    pthread_mutex_lock(&gStateMutex);
    Boolean changed = untunnel_liveness_update(&gLiveness, NowNanoseconds());
    pthread_mutex_unlock(&gStateMutex);
    if (changed) {
        NotifyDeviceListChanged();
    }
}

static void StartLivenessTimer(void) {
    dispatch_queue_t queue =
        dispatch_queue_create("com.intesarjawad.untunnel.driver.liveness", DISPATCH_QUEUE_SERIAL);
    gLivenessTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(
        gLivenessTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)kLivenessPollNanoseconds),
        kLivenessPollNanoseconds,
        kLivenessPollNanoseconds / 10);
    dispatch_source_set_event_handler(gLivenessTimer, ^{
        UpdateLiveness();
    });
    dispatch_resume(gLivenessTimer);
}

// MARK: - IUnknown

static HRESULT QueryInterface(void *driver, REFIID iid, LPVOID *interface);
static ULONG AddRef(void *driver);
static ULONG Release(void *driver);

// MARK: - Driver interface

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus CreateDevice(
    AudioServerPlugInDriverRef driver,
    CFDictionaryRef description,
    const AudioServerPlugInClientInfo *client,
    AudioObjectID *device);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID device);
static OSStatus AddDeviceClient(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    const AudioServerPlugInClientInfo *client);
static OSStatus RemoveDeviceClient(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    const AudioServerPlugInClientInfo *client);
static OSStatus PerformDeviceConfigurationChange(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt64 action,
    void *info);
static OSStatus AbortDeviceConfigurationChange(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt64 action,
    void *info);
static Boolean HasProperty(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address);
static OSStatus IsPropertySettable(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address,
    Boolean *settable);
static OSStatus GetPropertyDataSize(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize,
    const void *qualifier,
    UInt32 *size);
static OSStatus GetPropertyData(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize,
    const void *qualifier,
    UInt32 inSize,
    UInt32 *outSize,
    void *data);
static OSStatus SetPropertyData(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize,
    const void *qualifier,
    UInt32 size,
    const void *data);
static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client);
static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client);
static OSStatus GetZeroTimeStamp(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt32 client,
    Float64 *sampleTime,
    UInt64 *hostTime,
    UInt64 *seed);
static OSStatus WillDoIOOperation(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt32 client,
    UInt32 operation,
    Boolean *willDo,
    Boolean *willDoInPlace);
static OSStatus BeginIOOperation(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt32 client,
    UInt32 operation,
    UInt32 frames,
    const AudioServerPlugInIOCycleInfo *cycle);
static OSStatus DoIOOperation(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    AudioObjectID stream,
    UInt32 client,
    UInt32 operation,
    UInt32 frames,
    const AudioServerPlugInIOCycleInfo *cycle,
    void *mainBuffer,
    void *secondaryBuffer);
static OSStatus EndIOOperation(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt32 client,
    UInt32 operation,
    UInt32 frames,
    const AudioServerPlugInIOCycleInfo *cycle);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

void *Untunnel_Create(CFAllocatorRef allocator, CFUUIDRef requestedType);

void *Untunnel_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    return gDriver;
}

static HRESULT QueryInterface(void *driver, REFIID iid, LPVOID *interface) {
    if (driver != gDriver || interface == NULL) {
        return kAudioHardwareBadObjectError;
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, iid);
    if (requested == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    Boolean known = CFEqual(requested, IUnknownUUID)
        || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!known) {
        *interface = NULL;
        return E_NOINTERFACE;
    }
    pthread_mutex_lock(&gStateMutex);
    gRefCount++;
    pthread_mutex_unlock(&gStateMutex);
    *interface = gDriver;
    return S_OK;
}

static ULONG AddRef(void *driver) {
    if (driver != gDriver) {
        return 0;
    }
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Release(void *driver) {
    if (driver != gDriver) {
        return 0;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) {
        gRefCount--;
    }
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriver) {
        return kAudioHardwareBadObjectError;
    }
    gHost = host;

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double ticksPerSecond = 1e9 * (double)timebase.denom / (double)timebase.numer;
    untunnel_clock_init(&gClock, ticksPerSecond / kSampleRate, kRingFrames);
    untunnel_ring_init(&gRing, gRingStorage, kRingFrames);
    untunnel_liveness_init(
        &gLiveness,
        UNTUNNEL_LIVENESS_BY_CLIENTS ? UNTUNNEL_LIVENESS_CLIENTS : UNTUNNEL_LIVENESS_WRITES,
        kLivenessTimeoutNanoseconds);
    StartLivenessTimer();
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(
    AudioServerPlugInDriverRef driver,
    CFDictionaryRef description,
    const AudioServerPlugInClientInfo *client,
    AudioObjectID *device) {
    (void)driver;
    (void)description;
    (void)client;
    (void)device;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID device) {
    (void)driver;
    (void)device;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    const AudioServerPlugInClientInfo *client) {
    (void)client;
    if (driver != gDriver || !IsDevice(device)) {
        return kAudioHardwareBadObjectError;
    }
    if (device == kObjectID_Feed) {
        pthread_mutex_lock(&gStateMutex);
        untunnel_liveness_client_added(&gLiveness);
        pthread_mutex_unlock(&gStateMutex);
        UpdateLiveness();
    }
    return kAudioHardwareNoError;
}

static OSStatus RemoveDeviceClient(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    const AudioServerPlugInClientInfo *client) {
    (void)client;
    if (driver != gDriver || !IsDevice(device)) {
        return kAudioHardwareBadObjectError;
    }
    if (device == kObjectID_Feed) {
        pthread_mutex_lock(&gStateMutex);
        untunnel_liveness_client_removed(&gLiveness);
        pthread_mutex_unlock(&gStateMutex);
        UpdateLiveness();
    }
    return kAudioHardwareNoError;
}

static OSStatus PerformDeviceConfigurationChange(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt64 action,
    void *info) {
    (void)info;
    if (driver != gDriver || !IsDevice(device)) {
        return kAudioHardwareBadObjectError;
    }
    if (action != 1 && action != 2) {
        return kAudioHardwareBadDeviceError;
    }
    atomic_store(ChannelsOf(device), (UInt32)action);
    return kAudioHardwareNoError;
}

static OSStatus AbortDeviceConfigurationChange(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt64 action,
    void *info) {
    (void)action;
    (void)info;
    if (driver != gDriver || !IsDevice(device)) {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

// MARK: - Properties

static Boolean StreamInScope(AudioObjectID device, AudioObjectPropertyScope scope) {
    if (scope == kAudioObjectPropertyScopeGlobal) {
        return true;
    }
    return device == kObjectID_Microphone ? scope == kAudioObjectPropertyScopeInput
                                          : scope == kAudioObjectPropertyScopeOutput;
}

static Boolean HasPlugInProperty(AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyManufacturer:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
    case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioPlugInPropertyResourceBundle:
        return true;
    default:
        return false;
    }
}

static Boolean HasDeviceProperty(AudioObjectID device, AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyRelatedDevices:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertyStreams:
    case kAudioObjectPropertyControlList:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyPreferredChannelsForStereo:
    case kAudioDevicePropertyZeroTimeStampPeriod:
        return true;
    case kAudioObjectPropertyCustomPropertyInfoList:
    case kSelector_Heartbeat:
    case kSelector_Version:
        return device == kObjectID_Feed;
    default:
        return false;
    }
}

static Boolean HasStreamProperty(AudioObjectPropertySelector selector) {
    switch (selector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:
    case kAudioStreamPropertyLatency:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        return true;
    default:
        return false;
    }
}

static Boolean HasProperty(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address) {
    (void)client;
    if (driver != gDriver || address == NULL) {
        return false;
    }
    if (object == kAudioObjectPlugInObject) {
        return HasPlugInProperty(address->mSelector);
    }
    if (IsDevice(object)) {
        return HasDeviceProperty(object, address->mSelector);
    }
    if (IsStream(object)) {
        return HasStreamProperty(address->mSelector);
    }
    return false;
}

static OSStatus IsPropertySettable(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address,
    Boolean *settable) {
    if (driver != gDriver || settable == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!HasProperty(driver, object, client, address)) {
        return kAudioHardwareUnknownPropertyError;
    }
    switch (address->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
    case kSelector_Heartbeat:
        *settable = true;
        break;
    default:
        *settable = false;
        break;
    }
    return kAudioHardwareNoError;
}

static UInt32 PropertySize(AudioObjectID object, const AudioObjectPropertyAddress *address) {
    AudioObjectPropertySelector selector = address->mSelector;
    if (object == kAudioObjectPlugInObject) {
        switch (selector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            return sizeof(AudioClassID);
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            return sizeof(AudioObjectID);
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            return sizeof(CFStringRef);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID devices[2];
            return DeviceList(devices, 2) * (UInt32)sizeof(AudioObjectID);
        }
        default:
            return 0;
        }
    }
    if (IsDevice(object)) {
        switch (selector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            return sizeof(AudioClassID);
        case kAudioObjectPropertyOwner:
            return sizeof(AudioObjectID);
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            return sizeof(CFStringRef);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            return StreamInScope(object, address->mScope) ? sizeof(AudioObjectID) : 0;
        case kAudioDevicePropertyRelatedDevices:
            return sizeof(AudioObjectID);
        case kAudioObjectPropertyControlList:
            return 0;
        case kAudioDevicePropertyNominalSampleRate:
            return sizeof(Float64);
        case kAudioDevicePropertyAvailableNominalSampleRates:
            return sizeof(AudioValueRange);
        case kAudioDevicePropertyPreferredChannelsForStereo:
            return 2 * sizeof(UInt32);
        case kAudioObjectPropertyCustomPropertyInfoList:
            return 2 * sizeof(AudioServerPlugInCustomPropertyInfo);
        case kSelector_Heartbeat:
            return sizeof(CFPropertyListRef);
        case kSelector_Version:
            return sizeof(CFStringRef);
        default:
            return sizeof(UInt32);
        }
    }
    if (IsStream(object)) {
        switch (selector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            return sizeof(AudioClassID);
        case kAudioObjectPropertyOwner:
            return sizeof(AudioObjectID);
        case kAudioObjectPropertyOwnedObjects:
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return sizeof(AudioStreamBasicDescription);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return 2 * sizeof(AudioStreamRangedDescription);
        default:
            return sizeof(UInt32);
        }
    }
    return 0;
}

static OSStatus GetPropertyDataSize(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize,
    const void *qualifier,
    UInt32 *size) {
    (void)qualifierSize;
    (void)qualifier;
    if (driver != gDriver || size == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!HasProperty(driver, object, client, address)) {
        return kAudioHardwareUnknownPropertyError;
    }
    *size = PropertySize(object, address);
    return kAudioHardwareNoError;
}

#define WRITE_VALUE(type, value)                          \
    do {                                                  \
        if (inSize < sizeof(type)) {                      \
            return kAudioHardwareBadPropertySizeError;    \
        }                                                 \
        *(type *)data = (value);                          \
        *outSize = sizeof(type);                          \
        return kAudioHardwareNoError;                     \
    } while (0)

static OSStatus GetPlugInProperty(
    const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize,
    const void *qualifier,
    UInt32 inSize,
    UInt32 *outSize,
    void *data) {
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer:
        WRITE_VALUE(CFStringRef, (CFStringRef)CFRetain(kManufacturer));
    case kAudioPlugInPropertyResourceBundle:
        WRITE_VALUE(CFStringRef, (CFStringRef)CFRetain(CFSTR("")));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        UInt32 count = DeviceList((AudioObjectID *)data, inSize / (UInt32)sizeof(AudioObjectID));
        *outSize = count * (UInt32)sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (qualifierSize != sizeof(CFStringRef) || qualifier == NULL) {
            return kAudioHardwareBadPropertySizeError;
        }
        CFStringRef uid = *(const CFStringRef *)qualifier;
        AudioObjectID device = kAudioObjectUnknown;
        if (CFStringCompare(uid, kFeedUID, 0) == kCFCompareEqualTo) {
            device = kObjectID_Feed;
        } else if (
            CFStringCompare(uid, kMicrophoneUID, 0) == kCFCompareEqualTo && MicrophoneVisible()) {
            device = kObjectID_Microphone;
        }
        WRITE_VALUE(AudioObjectID, device);
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDeviceProperty(
    AudioObjectID device,
    const AudioObjectPropertyAddress *address,
    UInt32 inSize,
    UInt32 *outSize,
    void *data) {
    Boolean microphone = device == kObjectID_Microphone;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, kAudioObjectPlugInObject);
    case kAudioObjectPropertyName:
        WRITE_VALUE(CFStringRef, (CFStringRef)CFRetain(microphone ? kMicrophoneName : kFeedName));
    case kAudioObjectPropertyManufacturer:
        WRITE_VALUE(CFStringRef, (CFStringRef)CFRetain(kManufacturer));
    case kAudioDevicePropertyDeviceUID:
        WRITE_VALUE(CFStringRef, (CFStringRef)CFRetain(microphone ? kMicrophoneUID : kFeedUID));
    case kAudioDevicePropertyModelUID:
        WRITE_VALUE(CFStringRef, (CFStringRef)CFRetain(kModelUID));
    case kAudioDevicePropertyTransportType:
        WRITE_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices:
        WRITE_VALUE(AudioObjectID, device);
    case kAudioDevicePropertyClockDomain:
        WRITE_VALUE(UInt32, kClockDomain);
    case kAudioDevicePropertyDeviceIsAlive:
        WRITE_VALUE(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&gStateMutex);
        UInt32 running = (microphone ? gMicrophoneRunning : gFeedRunning) > 0;
        pthread_mutex_unlock(&gStateMutex);
        WRITE_VALUE(UInt32, running);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        WRITE_VALUE(UInt32, microphone && address->mScope != kAudioObjectPropertyScopeOutput);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        WRITE_VALUE(UInt32, 0);
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
        WRITE_VALUE(UInt32, 0);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams:
        if (!StreamInScope(device, address->mScope)) {
            *outSize = 0;
            return kAudioHardwareNoError;
        }
        WRITE_VALUE(AudioObjectID, StreamOf(device));
    case kAudioObjectPropertyControlList:
        *outSize = 0;
        return kAudioHardwareNoError;
    case kAudioDevicePropertyNominalSampleRate:
        WRITE_VALUE(Float64, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = {kSampleRate, kSampleRate};
        WRITE_VALUE(AudioValueRange, range);
    }
    case kAudioDevicePropertyIsHidden:
        WRITE_VALUE(UInt32, !microphone);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (inSize < 2 * sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        UInt32 channels = atomic_load(ChannelsOf(device));
        ((UInt32 *)data)[0] = 1;
        ((UInt32 *)data)[1] = channels > 1 ? 2 : 1;
        *outSize = 2 * sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyZeroTimeStampPeriod:
        WRITE_VALUE(UInt32, kRingFrames);
    case kAudioObjectPropertyCustomPropertyInfoList: {
        if (inSize < 2 * sizeof(AudioServerPlugInCustomPropertyInfo)) {
            return kAudioHardwareBadPropertySizeError;
        }
        AudioServerPlugInCustomPropertyInfo *info = data;
        info[0] = (AudioServerPlugInCustomPropertyInfo){
            kSelector_Heartbeat,
            kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
            kAudioServerPlugInCustomPropertyDataTypeNone,
        };
        info[1] = (AudioServerPlugInCustomPropertyInfo){
            kSelector_Version,
            kAudioServerPlugInCustomPropertyDataTypeCFString,
            kAudioServerPlugInCustomPropertyDataTypeNone,
        };
        *outSize = 2 * sizeof(AudioServerPlugInCustomPropertyInfo);
        return kAudioHardwareNoError;
    }
    case kSelector_Heartbeat: {
        SInt32 visible = MicrophoneVisible();
        WRITE_VALUE(CFPropertyListRef, CFNumberCreate(NULL, kCFNumberSInt32Type, &visible));
    }
    case kSelector_Version:
        WRITE_VALUE(CFStringRef, (CFStringRef)CFRetain(CFSTR(UNTUNNEL_DRIVER_VERSION)));
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamProperty(
    AudioObjectID stream,
    const AudioObjectPropertyAddress *address,
    UInt32 inSize,
    UInt32 *outSize,
    void *data) {
    AudioObjectID device = DeviceOf(stream);
    Boolean microphone = device == kObjectID_Microphone;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, device);
    case kAudioObjectPropertyOwnedObjects:
        *outSize = 0;
        return kAudioHardwareNoError;
    case kAudioStreamPropertyIsActive:
        WRITE_VALUE(UInt32, 1);
    case kAudioStreamPropertyDirection:
        WRITE_VALUE(UInt32, microphone ? 1 : 0);
    case kAudioStreamPropertyTerminalType:
        WRITE_VALUE(
            UInt32,
            microphone ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine);
    case kAudioStreamPropertyStartingChannel:
        WRITE_VALUE(UInt32, 1);
    case kAudioStreamPropertyLatency:
        WRITE_VALUE(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        WRITE_VALUE(AudioStreamBasicDescription, Format(atomic_load(ChannelsOf(device))));
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        if (inSize < 2 * sizeof(AudioStreamRangedDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        AudioStreamRangedDescription *formats = data;
        for (UInt32 index = 0; index < 2; index++) {
            formats[index].mFormat = Format(index + 1);
            formats[index].mSampleRateRange.mMinimum = kSampleRate;
            formats[index].mSampleRateRange.mMaximum = kSampleRate;
        }
        *outSize = 2 * sizeof(AudioStreamRangedDescription);
        return kAudioHardwareNoError;
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetPropertyData(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize,
    const void *qualifier,
    UInt32 inSize,
    UInt32 *outSize,
    void *data) {
    if (driver != gDriver || outSize == NULL || data == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!HasProperty(driver, object, client, address)) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (object == kAudioObjectPlugInObject) {
        return GetPlugInProperty(address, qualifierSize, qualifier, inSize, outSize, data);
    }
    if (IsDevice(object)) {
        return GetDeviceProperty(object, address, inSize, outSize, data);
    }
    return GetStreamProperty(object, address, inSize, outSize, data);
}

static OSStatus SetPropertyData(
    AudioServerPlugInDriverRef driver,
    AudioObjectID object,
    pid_t client,
    const AudioObjectPropertyAddress *address,
    UInt32 qualifierSize,
    const void *qualifier,
    UInt32 size,
    const void *data) {
    (void)qualifierSize;
    (void)qualifier;
    if (driver != gDriver || data == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!HasProperty(driver, object, client, address)) {
        return kAudioHardwareUnknownPropertyError;
    }
    switch (address->mSelector) {
    case kSelector_Heartbeat:
        untunnel_liveness_note_write(&gLiveness, NowNanoseconds());
        UpdateLiveness();
        return kAudioHardwareNoError;
    case kAudioDevicePropertyNominalSampleRate:
        if (size != sizeof(Float64)) {
            return kAudioHardwareBadPropertySizeError;
        }
        return *(const Float64 *)data == kSampleRate ? kAudioHardwareNoError
                                                     : kAudioDeviceUnsupportedFormatError;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        if (size != sizeof(AudioStreamBasicDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        const AudioStreamBasicDescription *format = data;
        UInt32 channels = format->mChannelsPerFrame;
        if (format->mFormatID != kAudioFormatLinearPCM
            || (format->mSampleRate != 0 && format->mSampleRate != kSampleRate)
            || (channels != 1 && channels != 2)) {
            return kAudioDeviceUnsupportedFormatError;
        }
        AudioObjectID device = DeviceOf(object);
        if (channels != atomic_load(ChannelsOf(device)) && gHost != NULL) {
            gHost->RequestDeviceConfigurationChange(gHost, device, channels, NULL);
        }
        return kAudioHardwareNoError;
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - IO

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    (void)client;
    if (driver != gDriver || !IsDevice(device)) {
        return kAudioHardwareBadObjectError;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gClockRunning++ == 0) {
        untunnel_clock_start(&gClock, mach_absolute_time());
    }
    if (device == kObjectID_Microphone) {
        gMicrophoneRunning++;
    } else if (gFeedRunning++ == 0) {
        untunnel_ring_clear(&gRing);
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    (void)client;
    if (driver != gDriver || !IsDevice(device)) {
        return kAudioHardwareBadObjectError;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gClockRunning > 0) {
        gClockRunning--;
    }
    if (device == kObjectID_Microphone) {
        if (gMicrophoneRunning > 0) {
            gMicrophoneRunning--;
        }
    } else if (gFeedRunning > 0 && --gFeedRunning == 0) {
        untunnel_ring_clear(&gRing);
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus GetZeroTimeStamp(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt32 client,
    Float64 *sampleTime,
    UInt64 *hostTime,
    UInt64 *seed) {
    (void)client;
    if (driver != gDriver || !IsDevice(device)) {
        return kAudioHardwareBadObjectError;
    }
    untunnel_clock_zero_time_stamp(&gClock, mach_absolute_time(), sampleTime, hostTime);
    *seed = 1;
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt32 client,
    UInt32 operation,
    Boolean *willDo,
    Boolean *willDoInPlace) {
    (void)client;
    if (driver != gDriver || !IsDevice(device)) {
        return kAudioHardwareBadObjectError;
    }
    Boolean handled = device == kObjectID_Microphone
        ? operation == kAudioServerPlugInIOOperationReadInput
        : operation == kAudioServerPlugInIOOperationWriteMix;
    *willDo = handled;
    *willDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt32 client,
    UInt32 operation,
    UInt32 frames,
    const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client;
    (void)operation;
    (void)frames;
    (void)cycle;
    return driver == gDriver && IsDevice(device) ? kAudioHardwareNoError
                                                 : kAudioHardwareBadObjectError;
}

static OSStatus DoIOOperation(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    AudioObjectID stream,
    UInt32 client,
    UInt32 operation,
    UInt32 frames,
    const AudioServerPlugInIOCycleInfo *cycle,
    void *mainBuffer,
    void *secondaryBuffer) {
    (void)client;
    (void)stream;
    (void)secondaryBuffer;
    if (driver != gDriver || !IsDevice(device) || mainBuffer == NULL) {
        return kAudioHardwareBadObjectError;
    }
    UInt32 channels = atomic_load(ChannelsOf(device));
    if (device == kObjectID_Microphone && operation == kAudioServerPlugInIOOperationReadInput) {
        untunnel_ring_read(
            &gRing, (int64_t)cycle->mInputTime.mSampleTime, mainBuffer, frames, channels);
    } else if (device == kObjectID_Feed && operation == kAudioServerPlugInIOOperationWriteMix) {
        untunnel_ring_write(
            &gRing, (int64_t)cycle->mOutputTime.mSampleTime, mainBuffer, frames, channels);
        untunnel_liveness_note_write(&gLiveness, NowNanoseconds());
    }
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device,
    UInt32 client,
    UInt32 operation,
    UInt32 frames,
    const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client;
    (void)operation;
    (void)frames;
    (void)cycle;
    return driver == gDriver && IsDevice(device) ? kAudioHardwareNoError
                                                 : kAudioHardwareBadObjectError;
}
