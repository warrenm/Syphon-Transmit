/*******************************************************************/
/*                                                                 */
/*                      ADOBE CONFIDENTIAL                         */
/*                   _ _ _ _ _ _ _ _ _ _ _ _ _                     */
/*                                                                 */
/* Copyright 2012 Adobe Systems Incorporated					   */
/* All Rights Reserved.                                            */
/*                                                                 */
/* NOTICE:  All information contained herein is, and remains the   */
/* property of Adobe Systems Incorporated and its suppliers, if    */
/* any.  The intellectual and technical concepts contained         */
/* herein are proprietary to Adobe Systems Incorporated and its    */
/* suppliers and may be covered by U.S. and Foreign Patents,       */
/* patents in process, and are protected by trade secret or        */
/* copyright law.  Dissemination of this information or            */
/* reproduction of this material is strictly forbidden unless      */
/* prior written permission is obtained from Adobe Systems         */
/* Incorporated.                                                   */
/*                                                                 */
/*******************************************************************/


#include "SyphonTransmitterPlugin.h"
#include <stdio.h>
#include <ctime>

#import <Accelerate/Accelerate.h>

using namespace SDK;

struct ClockInstanceData
{
	PrTime						startTime;
	PrTime						ticksPerSecond;
	PrTime						videoFrameRate;
	tmClockCallback				clockCallback;
	void **						callbackContextPtr;
	PrPlayID					playID;
	float						audioSampleRate;
	float **					audioBuffers;
	SDKSuites					suites;
};

	/* This plug-in defined function is called on a new thread when StartPlaybackClock is called.
	** It loops continuously, calling the tmClockCallback at regular intervals until playback ends.
	** We try to make a call at same frequency as the frame rate of the timeline (i.e. transmit instance)
	** TRICKY: How does the function know when playback ends and it should end the loop?
	** Answer: The ClockInstanceData passed in contains a pointer to the callbackContext.
	** When playback ends, the context is set to zero, and that's how it knows to end the loop. 
	*/
void UpdateClock(void* inInstanceData, csSDK_int32 inPluginID, prSuiteError inStatus)
{
    ClockInstanceData	*clockInstanceData	= 0;
    clock_t				latestClockTime = clock();
    PrTime				timeElapsed = 0;
    
    clockInstanceData = reinterpret_cast<ClockInstanceData*>(inInstanceData);
    
    // Calculate how long to wait in between clock updates
    clock_t timeBetweenClockUpdates = (clock_t)(clockInstanceData->videoFrameRate * CLOCKS_PER_SEC / clockInstanceData->ticksPerSecond);
    
    NSLog(@"New clock started with callback context 0x%llx.", (long long)*clockInstanceData->callbackContextPtr);
    
    // Loop as long as we have a valid clock callback.
    // It will be set to NULL when playback stops and this function can return.
    while (clockInstanceData->clockCallback && *clockInstanceData->callbackContextPtr)
    {
        // Calculate time elapsed since last time we checked the clock
        clock_t newTime = clock();
        clock_t tempTimeElapsed = newTime - latestClockTime;
        latestClockTime = newTime;
        
        // Convert tempTimeElapsed to PrTime
        timeElapsed = tempTimeElapsed * clockInstanceData->ticksPerSecond / CLOCKS_PER_SEC;
        
        clockInstanceData->clockCallback(*clockInstanceData->callbackContextPtr, timeElapsed);
        
        // Sleep for a frame's length
        // Try sleeping for the half the time, since Mac OS seems to oversleep :)
        useconds_t sleepTime = (useconds_t)(timeBetweenClockUpdates / 2);
        usleep(sleepTime);
    }
    
    NSLog( @"Clock with callback context %llx exited.", (long long)*clockInstanceData->callbackContextPtr);
    
    delete(clockInstanceData);
}

#pragma mark - Instance Methods

SyphonTransmitInstance::SyphonTransmitInstance(const tmInstance* inInstance,
                                               const SDKDevicePtr& inDevice,
                                               const SDKSettings& inSettings,
                                               const SDKSuites& inSuites,
                                               SyphonServerBase *syphonServer     )
:
mDevice(inDevice),
mSettings(inSettings),
mSuites(inSuites)
{
    mClockCallback = 0;
    mCallbackContext = 0;
    mUpdateClockRegistration = 0;
    mPlaying = kPrFalse;
    if(syphonServer)
    {
        NSLog(@"Assigning Plugin Syphon Server to instance %p", syphonServer);
#if defined(SYPHON_TRANSMIT_USE_METAL)
        mSyphonServerParentInstance = (SyphonMetalServer *)syphonServer;
        mCommandQueue = [mSyphonServerParentInstance.device newCommandQueue];
#else
        mSyphonServerParentInstance = (SyphonOpenGLServer *)syphonServer;
#endif
    }
    
    mSuites.TimeSuite->GetTicksPerSecond(&mTicksPerSecond);
}

#pragma mark -

SyphonTransmitInstance::~SyphonTransmitInstance()
{
#if defined(SYPHON_TRANSMIT_USE_METAL)
    [mCommandQueue release];
#endif
    // TODO: Do we want to nil our syphon handle here?
    // Does that fuck with retain count / release ?
}


#pragma mark - Query Video Mode

tmResult SyphonTransmitInstance::QueryVideoMode(const tmStdParms* inStdParms,
                                                const tmInstance* inInstance,
                                                csSDK_int32 inQueryIterationIndex,
                                                tmVideoMode* outVideoMode)
{
    outVideoMode->outWidth = 0;
    outVideoMode->outHeight = 0;
    outVideoMode->outPARNum = 0;
    outVideoMode->outPARDen = 0;
    outVideoMode->outFieldType = prFieldsNone;
    outVideoMode->outPixelFormat =  PrPixelFormat_BGRA_4444_8u;
    outVideoMode->outLatency = inInstance->inVideoFrameRate * 1; // Ask for 5 frames preroll
    
    mVideoFrameRate = inInstance->inVideoFrameRate;
    
    return tmResult_Success;
}

#pragma mark - Activate/Deactivate

tmResult SyphonTransmitInstance::ActivateDeactivate(const tmStdParms* inStdParms,
                                                    const tmInstance* inInstance,
                                                    PrActivationEvent inActivationEvent,
                                                    prBool inAudioActive,
                                                    prBool inVideoActive)
{
    NSLog(@"ActivateDeactivate called.");
    
    if (inAudioActive || inVideoActive)
    {
        //	mDevice->StartTransmit();
        if (inAudioActive && inVideoActive)
            NSLog(@"with audio active and video active.");
        else if (inAudioActive)
            NSLog(@"with audio active.");
        else
            NSLog(@"with video active.");			
    }
    else
    {
        //	mDevice->StopTransmit();
        NSLog(@"to deactivate.");
    }
    
    return tmResult_Success;
}
	
#pragma mark - Start Clock

tmResult SyphonTransmitInstance::StartPlaybackClock(const tmStdParms* inStdParms,
                                                    const tmInstance* inInstance,
                                                    const tmPlaybackClock* inClock)
{
    float frameTimeInSeconds	= 0;
    
    mClockCallback = inClock->inClockCallback;
    mCallbackContext = inClock->inCallbackContext;
    mPlaybackSpeed = inClock->inSpeed;
    mUpdateClockRegistration = 0;
    
    frameTimeInSeconds = (float) inClock->inStartTime / mTicksPerSecond;
    
    
    if (inClock->inPlayMode == playmode_Scrubbing)
    {
        NSLog(@"StartPlaybackClock called for time %7.2f. Scrubbing.", frameTimeInSeconds);
    }
    else if (inClock->inPlayMode == playmode_Playing)
    {
        NSLog(@"StartPlaybackClock called for time %7.2f. Playing.", frameTimeInSeconds);
    }
    
    // If not yet playing, and called to play,
    // then register our UpdateClock function that calls the audio callback asynchronously during playback
    // Note that StartPlaybackClock can be called multiple times without a StopPlaybackClock,
    // for example if changing playback speed in the timeline.
    // If already playing, we the callbackContext doesn't change, and we let the current clock continue.
    if (!mPlaying && inClock->inPlayMode == playmode_Playing)
    {
        mPlaying = kPrTrue;
        
        // Initialize the ClockInstanceData that the UpdateClock function will need
        // We allocate the data here, and the data will be disposed at the end of the UpdateClock function
        ClockInstanceData *instanceData = new ClockInstanceData;
        instanceData->startTime = inClock->inStartTime;
        instanceData->callbackContextPtr = &mCallbackContext;
        instanceData->clockCallback = mClockCallback;
        instanceData->ticksPerSecond = mTicksPerSecond;
        instanceData->videoFrameRate = mVideoFrameRate;
        instanceData->playID = inInstance->inPlayID;
        instanceData->suites = mSuites;
        
        // Cross-platform threading suites!
        mSuites.ThreadedWorkSuite->RegisterForThreadedWork(	&UpdateClock,
                                                           instanceData,
                                                           &mUpdateClockRegistration);

        mSuites.ThreadedWorkSuite->QueueThreadedWork(mUpdateClockRegistration, inInstance->inInstanceID);
    }
    
    return tmResult_Success;
}

#pragma mark - Stop Clock

tmResult SyphonTransmitInstance::StopPlaybackClock(const tmStdParms* inStdParms,
                                                   const tmInstance* inInstance)
{
    mClockCallback = 0;
    mCallbackContext = 0;
    mPlaying = kPrFalse;
    
    if (mUpdateClockRegistration)
    {
        mSuites.ThreadedWorkSuite->UnregisterForThreadedWork(mUpdateClockRegistration);
        mUpdateClockRegistration = 0;
    }
    
    NSLog(@"StopPlaybackClock called.");
    
    return tmResult_Success;
}

#pragma mark - Push Video

tmResult SyphonTransmitInstance::PushVideo(const tmStdParms* inStdParms,
                                           const tmInstance* inInstance,
                                           const tmPushVideo* inPushVideo)
{
    // Send the video frames to the hardware.  We also log frame info to the debug console.
    float frameTimeInSeconds = 0;
    prRect frameBounds;
    csSDK_uint32 parNum = 0,
    parDen = 0;
    PrPixelFormat pixelFormat = PrPixelFormat_Invalid;

    frameTimeInSeconds = (float) inPushVideo->inTime / mTicksPerSecond;
    mSuites.PPixSuite->GetBounds(inPushVideo->inFrames[0].inFrame, &frameBounds);
    mSuites.PPixSuite->GetPixelAspectRatio(inPushVideo->inFrames[0].inFrame, &parNum, &parDen);
    mSuites.PPixSuite->GetPixelFormat(inPushVideo->inFrames[0].inFrame, &pixelFormat);

    csSDK_int32 rowBytes = 0;
    mSuites.PPixSuite->GetRowBytes(inPushVideo->inFrames[0].inFrame, &rowBytes);

    char* pixels = NULL;
    mSuites.PPixSuite->GetPixels(inPushVideo->inFrames[0].inFrame,
                                 PrPPixBufferAccess_ReadOnly,
                                 &pixels);

    @autoreleasepool
    {
#if defined(SYPHON_TRANSMIT_USE_METAL)
        NSUInteger width = abs(frameBounds.right - frameBounds.left);
        NSUInteger height = abs(frameBounds.top - frameBounds.bottom);
        MTLRegion imageRegion = MTLRegionMake2D(0, 0, width, height);
        NSRect imageRect = NSMakeRect(0, 0, width, height);
        NSUInteger bytesPerRow = rowBytes;

        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                     width:width
                                                                                                    height:height
                                                                                                 mipmapped:NO];
        textureDescriptor.usage = MTLTextureUsageShaderRead;
        textureDescriptor.storageMode = MTLStorageModeManaged;
        // TODO: Keep a heap or pool of upload textures rather than reallocating every frame.
        id<MTLTexture> uploadTexture = [mSyphonServerParentInstance.device newTextureWithDescriptor:textureDescriptor];
        [uploadTexture replaceRegion:imageRegion mipmapLevel:0 withBytes:pixels bytesPerRow:bytesPerRow];

        id<MTLCommandBuffer> commandBuffer = [mCommandQueue commandBuffer];
        [mSyphonServerParentInstance publishFrameTexture:uploadTexture
                                         onCommandBuffer:commandBuffer
                                             imageRegion:imageRect
                                                 flipped:YES];
        [commandBuffer commit];

        [uploadTexture release];
#else
        // bind our syphon GL Context
        CGLSetCurrentContext(mSyphonServerParentInstance.context);

        NSRect syphonRect = NSMakeRect(0, 0, abs(frameBounds.right - frameBounds.left), abs(frameBounds.top - frameBounds.bottom));

        // TODO: use bind to draw frame of size / unbind
        GLuint texture = 0;
        glGenTextures(1, &texture);
        glEnable(GL_TEXTURE_RECTANGLE_EXT);
        glBindTexture(GL_TEXTURE_RECTANGLE_EXT, texture);

        GLuint bitsPerBlock = 32;
        GLuint blockWidth = 1;
        GLuint blockHeight = 1;

        size_t rowBitsPerBlock = bitsPerBlock / blockHeight;
        GLuint rowLength = rowBytes * 8 / rowBitsPerBlock * blockWidth;

        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, rowLength);
        glPixelStorei(GL_UNPACK_IMAGE_HEIGHT, (GLint)syphonRect.size.height);
        glPixelStorei(GL_UNPACK_LSB_FIRST, GL_FALSE);
        glPixelStorei(GL_UNPACK_SKIP_IMAGES, 0);
        glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
        glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
        glPixelStorei(GL_UNPACK_SWAP_BYTES, GL_FALSE);

        glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_TRUE);

        glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_SHARED_APPLE);
        glTextureRangeAPPLE(GL_TEXTURE_RECTANGLE_EXT, 32 * syphonRect.size.width * syphonRect.size.height, pixels);

        glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA, syphonRect.size.width, syphonRect.size.height, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, pixels);

        [mSyphonServerParentInstance publishFrameTexture:texture textureTarget:GL_TEXTURE_RECTANGLE_EXT imageRegion:syphonRect textureDimensions:syphonRect.size flipped:NO];

        glDeleteTextures(1, &texture);
#endif
    }

    // Dispose of the PPix(es) when done!
    for (int i=0; i< inPushVideo->inFrameCount; i++)
    {
        mSuites.PPixSuite->Dispose(inPushVideo->inFrames[i].inFrame);
    }

    return tmResult_Success;
}


#pragma mark - Trasmit Plugin Methods

SyphonTransmitPlugin::SyphonTransmitPlugin(tmStdParms* ioStdParms,
                                           tmPluginInfo* outPluginInfo)
{
    // Here, you could make sure hardware is available
    copyConvertStringLiteralIntoUTF16(PLUGIN_DISPLAY_NAME, outPluginInfo->outDisplayName);
    
    outPluginInfo->outAudioAvailable = kPrFalse;
    outPluginInfo->outAudioDefaultEnabled = kPrFalse;
    outPluginInfo->outClockAvailable = kPrFalse;	// Set this to kPrFalse if the transmitter handles video only
    outPluginInfo->outVideoAvailable = kPrTrue;
    outPluginInfo->outVideoDefaultEnabled = kPrTrue;
    outPluginInfo->outHasSetup = kPrFalse;
    
    // Acquire any suites needed!
    mSuites.SPBasic = ioStdParms->piSuites->utilFuncs->getSPBasicSuite();
    mSuites.SPBasic->AcquireSuite(kPrSDKPPixSuite, kPrSDKPPixSuiteVersion, const_cast<const void**>(reinterpret_cast<void**>(&mSuites.PPixSuite)));
    mSuites.SPBasic->AcquireSuite(kPrSDKThreadedWorkSuite, kPrSDKThreadedWorkSuiteVersion3, const_cast<const void**>(reinterpret_cast<void**>(&mSuites.ThreadedWorkSuite)));
    mSuites.SPBasic->AcquireSuite(kPrSDKTimeSuite, kPrSDKTimeSuiteVersion, const_cast<const void**>(reinterpret_cast<void**>(&mSuites.TimeSuite)));

    @autoreleasepool
    {
#if defined(SYPHON_TRANSMIT_USE_METAL)
        // TODO: Add plugin UI to select Metal device.
        mMetalDevice = MTLCreateSystemDefaultDevice();

        if (mMetalDevice) {
            mSyphonServer = [[SyphonMetalServer alloc] initWithName:@"Selected Source"
                                                             device:mMetalDevice
                                                            options:@{ SyphonServerOptionIsPrivate : @NO }];

            NSLog(@"Initialized Syphon Server %@ description: %@, for instance %p, with device %@",
                  mSyphonServer, [mSyphonServer serverDescription], this, mMetalDevice);
        }
#else
        CGLPixelFormatObj mPxlFmt = NULL;
        CGLPixelFormatAttribute attribs[] = {kCGLPFAAccelerated, kCGLPFANoRecovery, (CGLPixelFormatAttribute)NULL};
        
        CGLError err = kCGLNoError;
        GLint numPixelFormats = 0;
        
        err = CGLChoosePixelFormat(attribs, &mPxlFmt, &numPixelFormats);
        
        if(err != kCGLNoError)
        {
            NSLog(@"Error choosing pixel format %s", CGLErrorString(err));
        }
        
        err = CGLCreateContext(mPxlFmt, NULL, &mCGLContext);
        
        if(err != kCGLNoError)
        {
            NSLog(@"Error creating context %s", CGLErrorString(err));
        }
        
        if(mCGLContext)
        {
            mSyphonServer = [[SyphonOpenGLServer alloc] initWithName:@"Selected Source" context:mCGLContext options:@{SyphonServerOptionIsPrivate : @NO}];
            
            NSLog(@"Initting Syphon Server %@ description: %@,  for instance %p", mSyphonServer, [mSyphonServer serverDescription], this);
        }
#endif
    }
}

#pragma mark - Shutdown

SyphonTransmitPlugin::~SyphonTransmitPlugin()
{
    // Be a good citizen and dispose of any suites used
    mSuites.SPBasic->ReleaseSuite(kPrSDKPPixSuite, kPrSDKPPixSuiteVersion);
    mSuites.SPBasic->ReleaseSuite(kPrSDKThreadedWorkSuite, kPrSDKThreadedWorkSuiteVersion3);
    mSuites.SPBasic->ReleaseSuite(kPrSDKTimeSuite, kPrSDKTimeSuiteVersion);
    
    @autoreleasepool
    {
        if(mSyphonServer)
        {
            NSLog(@"Releasing Syphon Server %@,  for instance %p", mSyphonServer, this);
            [mSyphonServer stop];
            mSyphonServer = nil;
        }
#if defined(SYPHON_TRANSMIT_USE_METAL)
        [mMetalDevice release];
        mMetalDevice = nil;
#else
        if(mCGLContext)
        {
            CGLReleaseContext(mCGLContext);
            mCGLContext = NULL;
        }
#endif
    }
}

#pragma mark - Setup Dialog (N/A?)

tmResult SyphonTransmitPlugin::SetupDialog(tmStdParms* ioStdParms,
                                           prParentWnd inParentWnd)
{
    // Get the settings, display a modal setup dialog for the user
    // MessageBox()
    
    // If the user changed the settings, save the new settings back to
    // ioStdParms->ioSerializedPluginData, and update ioStdParms->ioSerializedPluginDataSize
    
    return tmResult_Success;
}
	
#pragma mark - Reset

tmResult SyphonTransmitPlugin::NeedsReset(const tmStdParms* inStdParms,
                                          prBool* outResetModule)
{
    NSLog(@"Reset Plugin");
    // Did the hardware change?
    // if (it did)
    //{
    //	*outResetModule = kPrTrue;
    //}
    return tmResult_Success;
}
	
#pragma mark - Create

void* SyphonTransmitPlugin::CreateInstance(const tmStdParms* inStdParms,
                                           tmInstance* inInstance)
{
    return new SyphonTransmitInstance(inInstance, mDevice, mSettings, mSuites, mSyphonServer);
}

#pragma mark - Dispose

void SyphonTransmitPlugin::DisposeInstance(const tmStdParms* inStdParms,
                                           tmInstance* inInstance)
{
    delete (SyphonTransmitInstance*)inInstance->ioPrivateInstanceData;
}
