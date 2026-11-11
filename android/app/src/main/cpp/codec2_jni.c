// JNI bridge for the vendored Codec2 1.2.0 codec.
//
// Only the handful of calls the app needs are exposed: create/destroy, frame
// geometry, encode and decode. Everything else (file formats, OFDM modems) is
// dead weight on a phone.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

#include "codec2.h"

#define UNUSED(x) (void)(x)

JNIEXPORT jint JNICALL
Java_com_example_voice_Codec2Bridge_modeSupported(JNIEnv *env, jobject thiz,
                                                  jint mode) {
  UNUSED(env);
  UNUSED(thiz);
  switch (mode) {
    case CODEC2_MODE_3200:
    case CODEC2_MODE_2400:
    case CODEC2_MODE_1600:
    case CODEC2_MODE_1400:
    case CODEC2_MODE_1300:
    case CODEC2_MODE_1200:
    case CODEC2_MODE_700C:
      return 1;
    default:
      return 0;
  }
}

JNIEXPORT jlong JNICALL
Java_com_example_voice_Codec2Bridge_create(JNIEnv *env, jobject thiz,
                                           jint mode) {
  UNUSED(env);
  UNUSED(thiz);
  struct CODEC2 *codec = codec2_create((int)mode);
  return (jlong)(intptr_t)codec;
}

JNIEXPORT void JNICALL
Java_com_example_voice_Codec2Bridge_destroy(JNIEnv *env, jobject thiz,
                                            jlong handle) {
  UNUSED(env);
  UNUSED(thiz);
  struct CODEC2 *codec = (struct CODEC2 *)(intptr_t)handle;
  if (codec != NULL) codec2_destroy(codec);
}

JNIEXPORT jint JNICALL
Java_com_example_voice_Codec2Bridge_samplesPerFrame(JNIEnv *env, jobject thiz,
                                                    jlong handle) {
  UNUSED(env);
  UNUSED(thiz);
  struct CODEC2 *codec = (struct CODEC2 *)(intptr_t)handle;
  if (codec == NULL) return 0;
  return codec2_samples_per_frame(codec);
}

JNIEXPORT jint JNICALL
Java_com_example_voice_Codec2Bridge_bytesPerFrame(JNIEnv *env, jobject thiz,
                                                  jlong handle) {
  UNUSED(env);
  UNUSED(thiz);
  struct CODEC2 *codec = (struct CODEC2 *)(intptr_t)handle;
  if (codec == NULL) return 0;
  return (codec2_bits_per_frame(codec) + 7) / 8;
}

JNIEXPORT jint JNICALL
Java_com_example_voice_Codec2Bridge_encode(JNIEnv *env, jobject thiz,
                                           jlong handle, jshortArray pcm,
                                           jbyteArray bits) {
  UNUSED(env);
  UNUSED(thiz);
  struct CODEC2 *codec = (struct CODEC2 *)(intptr_t)handle;
  if (codec == NULL || pcm == NULL || bits == NULL) return -1;

  const jsize samples = (*env)->GetArrayLength(env, pcm);
  const jsize bytes = (*env)->GetArrayLength(env, bits);
  const int needSamples = codec2_samples_per_frame(codec);
  const int needBytes = (codec2_bits_per_frame(codec) + 7) / 8;
  if (samples != needSamples || bytes != needBytes) return -2;

  jshort *pcmPtr = (*env)->GetShortArrayElements(env, pcm, NULL);
  jbyte *bitPtr = (*env)->GetByteArrayElements(env, bits, NULL);
  if (pcmPtr == NULL || bitPtr == NULL) {
    if (pcmPtr != NULL) (*env)->ReleaseShortArrayElements(env, pcm, pcmPtr, JNI_ABORT);
    if (bitPtr != NULL) (*env)->ReleaseByteArrayElements(env, bits, bitPtr, JNI_ABORT);
    return -3;
  }

  codec2_encode(codec, (unsigned char *)bitPtr, pcmPtr);

  (*env)->ReleaseShortArrayElements(env, pcm, pcmPtr, JNI_ABORT);
  (*env)->ReleaseByteArrayElements(env, bits, bitPtr, 0);
  return needBytes;
}

JNIEXPORT jint JNICALL
Java_com_example_voice_Codec2Bridge_decode(JNIEnv *env, jobject thiz,
                                           jlong handle, jbyteArray bits,
                                           jshortArray pcm) {
  UNUSED(env);
  UNUSED(thiz);
  struct CODEC2 *codec = (struct CODEC2 *)(intptr_t)handle;
  if (codec == NULL || pcm == NULL || bits == NULL) return -1;

  const jsize samples = (*env)->GetArrayLength(env, pcm);
  const jsize bytes = (*env)->GetArrayLength(env, bits);
  const int needSamples = codec2_samples_per_frame(codec);
  const int needBytes = (codec2_bits_per_frame(codec) + 7) / 8;
  if (samples != needSamples || bytes != needBytes) return -2;

  jbyte *bitPtr = (*env)->GetByteArrayElements(env, bits, NULL);
  jshort *pcmPtr = (*env)->GetShortArrayElements(env, pcm, NULL);
  if (pcmPtr == NULL || bitPtr == NULL) {
    if (pcmPtr != NULL) (*env)->ReleaseShortArrayElements(env, pcm, pcmPtr, JNI_ABORT);
    if (bitPtr != NULL) (*env)->ReleaseByteArrayElements(env, bits, bitPtr, JNI_ABORT);
    return -3;
  }

  codec2_decode(codec, pcmPtr, (const unsigned char *)bitPtr);

  (*env)->ReleaseByteArrayElements(env, bits, bitPtr, JNI_ABORT);
  (*env)->ReleaseShortArrayElements(env, pcm, pcmPtr, 0);
  return needSamples;
}
