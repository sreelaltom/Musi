
package com.golanpiyush.yt_flutter_musicapi

import io.flutter.plugin.common.EventChannel
import com.chaquo.python.PyObject
import kotlinx.coroutines.*
import android.util.Log
import com.golanpiyush.yt_flutter_musicapi.SearchManager
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@OptIn(ExperimentalCoroutinesApi::class)
class SearchStreamHandler(private val plugin: YtFlutterMusicapiPlugin) : EventChannel.StreamHandler {
    companion object {
        const val SEARCH_TYPE = YtFlutterMusicapiPlugin.SEARCH_TYPE_SEARCH
        const val ITEM_TIMEOUT = 10000L // Reduced from 20s to 10s
        const val BATCH_SIZE = 3 // Process in small batches
    }
    
    private var eventSink: EventChannel.EventSink? = null
    private var searchId: String? = null
    private var job: Job? = null
    private var pythonExecutor: ExecutorService? = null
    private val executorLock = Object()
    
    private fun getOrCreateExecutor(): ExecutorService {
        return synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown && !it.isTerminated } ?: run {
                Executors.newSingleThreadExecutor { r ->
                    Thread(r, "PythonExecutor-Search").apply { isDaemon = true }
                }.also { pythonExecutor = it }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val args = arguments as? Map<*, *> ?: run {
            events?.error("INVALID_ARGUMENTS", "Arguments must be a map", null)
            return
        }

        job = plugin.coroutineScope.launch {
            try {
                Log.d("YTMusicAPI", "SearchStreamHandler: Starting search execution")
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Listening on searchId = $searchId")

                val query = args["query"] as? String ?: throw IllegalArgumentException("Query is required")
                searchId = "search_${query.hashCode()}_${System.currentTimeMillis()}"

                plugin.searchManager.cancelType(SEARCH_TYPE)
                
                val limit = args["limit"] as? Int ?: 50
                val thumbQuality = args["thumbQuality"] as? String ?: "VERY_HIGH" 
                val audioQuality = args["audioQuality"] as? String ?: "VERY_HIGH"
                val includeAudioUrl = args["includeAudioUrl"] as? Boolean ?: true
                val includeAlbumArt = args["includeAlbumArt"] as? Boolean ?: true

                val searcher = plugin.getMusicSearcher() ?: throw IllegalStateException("Music searcher not initialized")

                Log.d("YTMusicAPI", "SearchStreamHandler: Creating generator for query: $query")
                
                val generator = withContext(Dispatchers.IO) {
                    suspendCancellableCoroutine<PyObject> { continuation ->
                        val executor = getOrCreateExecutor()
                        try {
                            executor.execute {
                                try {
                                    val result = searcher.callAttr(
                                        "get_music_details",
                                        query,
                                        limit,
                                        plugin.getPythonThumbnailQuality(thumbQuality),
                                        plugin.getPythonAudioQuality(audioQuality),
                                        includeAudioUrl,
                                        includeAlbumArt
                                    )
                                    continuation.resume(result)
                                } catch (e: Exception) {
                                    continuation.resumeWithException(e)
                                }
                            }
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }
                        
                        continuation.invokeOnCancellation {
                            Log.d("YTMusicAPI", "SearchStreamHandler: Generator creation cancelled")
                        }
                    }
                }

                plugin.searchManager.registerSearch(searchId!!, SEARCH_TYPE, generator, job!!)

                Log.d("YTMusicAPI", "SearchStreamHandler: Starting iteration")
                
                processSearchResults(generator, events, limit)
                
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.endOfStream()
                    }
                }
                
            } catch (e: TimeoutCancellationException) {
                Log.e("YTMusicAPI", "SearchStreamHandler: Overall timeout", e)
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("TIMEOUT_ERROR", "Search request timed out", null)
                    }
                }
            } catch (e: CancellationException) {
                Log.d("YTMusicAPI", "SearchStreamHandler: Search cancelled")
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "SearchStreamHandler: Stream error: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("STREAM_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            } finally {
                // ✅ Cancel old stream if still active
                searchId?.let {
                    if (plugin.searchManager.has(it)) {
                        plugin.searchManager.cancelSearch(it)
                    } else {
                        Log.d("YTMusicAPI", "Search $it already cleaned up")
                    }
                }
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Cleaning up searchId = $searchId (job=${job?.isCancelled})")

                withContext(Dispatchers.Main.immediate) {
                    events?.endOfStream()  // ✔ ensures Flutter doesn't hang
                }
            }
        }
    }

    private suspend fun processSearchResults(generator: PyObject, events: EventChannel.EventSink?, limit: Int) {
        var itemCount = 0
        val cancelled = AtomicBoolean(false)
        val iterator = generator.callAttr("__iter__")
        val resultBuffer = mutableListOf<Map<String, Any>>()

        while (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE) && itemCount < limit && !cancelled.get()) {
            try {
                // Get item with reduced timeout
                val item = withTimeoutOrNull(ITEM_TIMEOUT) {
                    suspendCancellableCoroutine<PyObject?> { continuation ->
                        val executor = getOrCreateExecutor()
                        try {
                            executor.execute {
                                try {
                                    val result = iterator.callAttr("__next__")
                                    continuation.resume(result)
                                } catch (e: Exception) {
                                    if (e.message?.contains("StopIteration") == true || 
                                        e.toString().contains("StopIteration")) {
                                        continuation.resume(null)
                                    } else {
                                        continuation.resumeWithException(e)
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }
                        
                        continuation.invokeOnCancellation {
                            cancelled.set(true)
                        }
                    }
                }
                
                if (item == null || item.isNone) {
                    break
                }
                
                val songData = plugin.convertPythonDictToMap(item)
                
                // Buffer results and send in batches
                resultBuffer.add(mapOf(
                    "title" to (songData["title"]?.toString() ?: "Unknown"),
                    "artists" to (songData["artists"]?.toString() ?: "Unknown"), 
                    "videoId" to (songData["videoId"]?.toString() ?: ""),
                    "duration" to (songData["duration"]?.toString() ?: ""),
                    "year" to (songData["year"]?.toString() ?: ""),
                    "albumArt" to (songData["albumArt"]?.toString() ?: ""),
                    "audioUrl" to (songData["audioUrl"]?.toString() ?: "")
                ))
                
                itemCount++
                
                // Send batch when full or at limit
                if (resultBuffer.size >= BATCH_SIZE || itemCount >= limit) {
                    withContext(Dispatchers.Main) {
                        if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                            for (result in resultBuffer) {
                                events?.success(result)
                            }
                            resultBuffer.clear()
                        }
                    }
                }
                
                yield()
                
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "Error processing item: ${e.message}", e)
                if (itemCount == 0) throw e
                continue
            }
        }
        
        // Send any remaining buffered results
        if (resultBuffer.isNotEmpty()) {
            withContext(Dispatchers.Main) {
                if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                    for (result in resultBuffer) {
                        events?.success(result)
                    }
                }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        Log.d("YTMusicAPI", "SearchStreamHandler: onCancel called")
        job?.cancel()
        searchId?.let { plugin.searchManager.cancelSearch(it) }
        eventSink = null
        
        synchronized(executorLock) {
            pythonExecutor?.let { executor ->
                if (!executor.isShutdown) {
                    executor.shutdown()
                }
            }
            pythonExecutor = null
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class RelatedSongsStreamHandler(private val plugin: YtFlutterMusicapiPlugin) : EventChannel.StreamHandler {
    companion object {
        const val SEARCH_TYPE = YtFlutterMusicapiPlugin.SEARCH_TYPE_RELATED
    }
    
    private var eventSink: EventChannel.EventSink? = null
    private var searchId: String? = null
    private var job: Job? = null
    private var pythonExecutor: ExecutorService? = null
    private val executorLock = Object()
    
    private fun getOrCreateExecutor(): ExecutorService {
        return synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown && !it.isTerminated } ?: run {
                Executors.newSingleThreadExecutor { r ->
                    Thread(r, "PythonExecutor-Related").apply { isDaemon = true }
                }.also { pythonExecutor = it }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val args = arguments as? Map<*, *> ?: run {
            events?.error("INVALID_ARGUMENTS", "Arguments must be a map", null)
            return
        }

        job = plugin.coroutineScope.launch {
            try {
                Log.d("YTMusicAPI", "RelatedSongsStreamHandler: Starting related songs execution")
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Listening on searchId = $searchId")

                val songName = args["songName"] as? String ?: throw IllegalArgumentException("Song name required")
                val artistName = args["artistName"] as? String ?: throw IllegalArgumentException("Artist name required")
                searchId = "related_${songName.hashCode()}_${artistName.hashCode()}_${System.currentTimeMillis()}"

                plugin.searchManager.cancelType(SEARCH_TYPE)
                
                val limit = args["limit"] as? Int ?: 100
                val thumbQuality = args["thumbQuality"] as? String ?: "VERY_HIGH"
                val audioQuality = args["audioQuality"] as? String ?: "HIGH"
                val includeAudioUrl = args["includeAudioUrl"] as? Boolean ?: true
                val includeAlbumArt = args["includeAlbumArt"] as? Boolean ?: true

                val fetcher = plugin.getRelatedFetcher() ?: throw IllegalStateException("Related fetcher not initialized")

                Log.d("YTMusicAPI", "RelatedSongsStreamHandler: Creating generator for $songName by $artistName")
                
                val generator = suspendCancellableCoroutine<PyObject> { continuation ->
                    val executor = getOrCreateExecutor()
                    try {
                        executor.execute {
                            try {
                                val result = fetcher.callAttr(
                                    "getRelated",
                                    songName,
                                    artistName,
                                    limit,
                                    plugin.getPythonThumbnailQuality(thumbQuality),
                                    plugin.getPythonAudioQuality(audioQuality),
                                    includeAudioUrl,
                                    includeAlbumArt
                                )
                                continuation.resume(result)
                            } catch (e: Exception) {
                                continuation.resumeWithException(e)
                            }
                        }
                    } catch (e: Exception) {
                        continuation.resumeWithException(e)
                    }
                    
                    continuation.invokeOnCancellation {
                        Log.d("YTMusicAPI", "RelatedSongsStreamHandler: Generator creation cancelled")
                    }
                }

                plugin.searchManager.registerSearch(searchId!!, SEARCH_TYPE, generator, job!!)

                Log.d("YTMusicAPI", "RelatedSongsStreamHandler: Starting iteration")
                
                processRelatedResults(generator, events, limit)
                
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.endOfStream()
                    }
                }
                
            } catch (e: TimeoutCancellationException) {
                Log.e("YTMusicAPI", "RelatedSongsStreamHandler: Overall timeout", e)
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("TIMEOUT_ERROR", "Related songs request timed out", null)
                    }
                }
            } catch (e: CancellationException) {
                Log.d("YTMusicAPI", "RelatedSongsStreamHandler: Search cancelled")
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "RelatedSongsStreamHandler: Stream error", e)
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("STREAM_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            } finally {
                // ✅ Cancel old stream if still active
                searchId?.let {
                    if (plugin.searchManager.has(it)) {
                        plugin.searchManager.cancelSearch(it)
                    } else {
                        Log.d("YTMusicAPI", "Search $it already cleaned up")
                    }
                }
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Cleaning up searchId = $searchId (job=${job?.isCancelled})")

                withContext(Dispatchers.Main.immediate) {
                    events?.endOfStream()  // ✔ ensures Flutter doesn't hang
                }
            }
        }
    }

    private suspend fun processRelatedResults(generator: PyObject, events: EventChannel.EventSink?, limit: Int) {
        var itemCount = 0
        val cancelled = AtomicBoolean(false)
        val iterator = generator.callAttr("__iter__")

        while (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE) && itemCount < limit && !cancelled.get()) {
            try {
                Log.d("YTMusicAPI", "RelatedSongsStreamHandler: Attempting to get next item ($itemCount)")
                
                val item = withTimeoutOrNull(20000L) {
                    suspendCancellableCoroutine<PyObject?> { continuation ->
                        val executor = getOrCreateExecutor()
                        try {
                            executor.execute {
                                try {
                                    val result = iterator.callAttr("__next__")
                                    continuation.resume(result)
                                } catch (e: Exception) {
                                    if (e.message?.contains("StopIteration") == true || 
                                        e.toString().contains("StopIteration")) {
                                        continuation.resume(null)
                                    } else {
                                        continuation.resumeWithException(e)
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }
                        
                        continuation.invokeOnCancellation {
                            cancelled.set(true)
                        }
                    }
                }
                
                if (item == null || item.isNone) {
                    Log.d("YTMusicAPI", "RelatedSongsStreamHandler: No more items")
                    break
                }
                
                val songData = plugin.convertPythonDictToMap(item)
                Log.d("YTMusicAPI", "RelatedSongsStreamHandler: Processing item: ${songData["title"]}")
                
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.success(mapOf(
                            "title" to (songData["title"]?.toString() ?: "Unknown"),
                            "artists" to (songData["artists"]?.toString() ?: "Unknown"),
                            "videoId" to (songData["videoId"]?.toString() ?: ""),
                            "duration" to (songData["duration"]?.toString() ?: ""),
                            "albumArt" to (songData["albumArt"]?.toString() ?: ""),
                            "audioUrl" to (songData["audioUrl"]?.toString() ?: ""),
                            "isOriginal" to (songData["isOriginal"]?.toString()?.toBoolean() ?: false)
                        ))
                    }
                }
                
                itemCount++
                Log.d("YTMusicAPI", "RelatedSongsStreamHandler: Processed $itemCount items")
                
                yield()
                
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "RelatedSongsStreamHandler: Error processing item $itemCount: ${e.message}", e)
                if (itemCount == 0) {
                    throw e
                }
                continue
            }
        }

        Log.d("YTMusicAPI", "RelatedSongsStreamHandler: Finished processing $itemCount items")
    }

    override fun onCancel(arguments: Any?) {
        Log.d("YTMusicAPI", "RelatedSongsStreamHandler: onCancel called")
        job?.cancel()
        searchId?.let { plugin.searchManager.cancelSearch(it) }
        eventSink = null
        
        synchronized(executorLock) {
            pythonExecutor?.let { executor ->
                if (!executor.isShutdown) {
                    executor.shutdown()
                }
            }
            pythonExecutor = null
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ArtistSongsStreamHandler(private val plugin: YtFlutterMusicapiPlugin) : EventChannel.StreamHandler {

    companion object {
        const val SEARCH_TYPE = YtFlutterMusicapiPlugin.SEARCH_TYPE_ARTIST
    }

    private var eventSink: EventChannel.EventSink? = null
    private var searchId: String? = null
    private var job: Job? = null
    private var pythonExecutor: ExecutorService? = null
    private val executorLock = Object()

    private fun getOrCreateExecutor(): ExecutorService {
        return synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown && !it.isTerminated } ?: run {
                Executors.newSingleThreadExecutor { r ->
                    Thread(r, "PythonExecutor-Artist").apply { isDaemon = true }
                }.also { pythonExecutor = it }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val args = arguments as? Map<*, *> ?: run {
            events?.error("INVALID_ARGUMENTS", "Arguments must be a map", null)
            return
        }

        job = plugin.coroutineScope.launch {
            try {
                Log.d("YTMusicAPI", "ArtistSongsStreamHandler: Starting artist songs execution")
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Listening on searchId = $searchId")


                val artistName = args["artistName"] as? String ?: throw IllegalArgumentException("artistName required")
                searchId = "artist_${artistName.hashCode()}_${System.currentTimeMillis()}"

                val limit = args["limit"] as? Int ?: 80
                val thumbQuality = args["thumbQuality"] as? String ?: "VERY_HIGH"
                val audioQuality = args["audioQuality"] as? String ?: "HIGH"
                val includeAudioUrl = args["includeAudioUrl"] as? Boolean ?: true
                val includeAlbumArt = args["includeAlbumArt"] as? Boolean ?: true

                plugin.searchManager.cancelType(SEARCH_TYPE)

                val searcher = plugin.getMusicSearcher() ?: throw IllegalStateException("Music searcher unavailable")

                Log.d("YTMusicAPI", "ArtistSongsStreamHandler: Creating generator for: $artistName")

                val generator = suspendCancellableCoroutine<PyObject> { continuation ->
                    val executor = getOrCreateExecutor()
                    try {
                        executor.execute {
                            try {
                                val result = searcher.callAttr(
                                    "get_artist_songs",
                                    artistName,
                                    limit,
                                    thumbQuality,
                                    audioQuality,
                                    includeAudioUrl,
                                    includeAlbumArt
                                )
                                continuation.resume(result)
                            } catch (e: Exception) {
                                continuation.resumeWithException(e)
                            }
                        }
                    } catch (e: Exception) {
                        continuation.resumeWithException(e)
                    }

                    continuation.invokeOnCancellation {
                        Log.d("YTMusicAPI", "ArtistSongsStreamHandler: Generator creation cancelled")
                    }
                }

                plugin.searchManager.registerSearch(searchId!!, SEARCH_TYPE, generator, job!!)

                Log.d("YTMusicAPI", "ArtistSongsStreamHandler: Starting iteration")
                processArtistResults(generator, events, limit, artistName)

                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.endOfStream()
                    }
                }

            } catch (e: TimeoutCancellationException) {
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("TIMEOUT_ERROR", "Artist songs request timed out", null)
                    }
                }
            } catch (e: CancellationException) {
                Log.d("YTMusicAPI", "ArtistSongsStreamHandler: Search cancelled")
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "ArtistSongsStreamHandler: Stream error", e)
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("STREAM_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            } finally {
                searchId?.let {
                    if (plugin.searchManager.has(it)) {
                        plugin.searchManager.cancelSearch(it)
                    }
                }
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Cleaning up searchId = $searchId (job=${job?.isCancelled})")

                withContext(Dispatchers.Main.immediate) {
                    eventSink?.endOfStream()
                }
            }

        }
    }

    private suspend fun processArtistResults(generator: PyObject, events: EventChannel.EventSink?, limit: Int, artistName: String) {
        var itemCount = 0
        val cancelled = AtomicBoolean(false)
        val iterator = generator.callAttr("__iter__")

        while (
            plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE) &&
            itemCount < limit &&
            !cancelled.get()
        ) {
            try {
                Log.d("YTMusicAPI", "ArtistSongsStreamHandler: Getting item $itemCount")

                val item = withTimeoutOrNull(20000L) {
                    suspendCancellableCoroutine<PyObject?> { continuation ->
                        val executor = getOrCreateExecutor()
                        try {
                            executor.execute {
                                try {
                                    val result = iterator.callAttr("__next__")
                                    continuation.resume(result)
                                } catch (e: Exception) {
                                    if (e.message?.contains("StopIteration") == true) {
                                        continuation.resume(null)
                                    } else {
                                        continuation.resumeWithException(e)
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }

                        continuation.invokeOnCancellation {
                            cancelled.set(true)
                        }
                    }
                }

                if (item == null || item.isNone) {
                    Log.d("YTMusicAPI", "ArtistSongsStreamHandler: No more items")
                    break
                }

                val songData = plugin.convertPythonDictToMap(item)
                Log.d("YTMusicAPI", "ArtistSongsStreamHandler: Processing: ${songData["title"]}")

                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.success(
                            mapOf(
                                "title" to (songData["title"]?.toString() ?: "Unknown"),
                                "artists" to (songData["artists"]?.toString() ?: "Unknown"),
                                "videoId" to (songData["videoId"]?.toString() ?: ""),
                                "duration" to (songData["duration"]?.toString() ?: ""),
                                "albumArt" to (songData["albumArt"]?.toString() ?: ""),
                                "audioUrl" to (songData["audioUrl"]?.toString() ?: ""),
                                "artistName" to artistName
                            )
                        )
                    } else {
                        Log.d("YTMusicAPI", "⚠️ Skipped result for stale search: $searchId")
                    }
                }

                itemCount++
                Log.d("YTMusicAPI", "ArtistSongsStreamHandler: Processed $itemCount items")

                yield()

            } catch (e: Exception) {
                Log.e("YTMusicAPI", "ArtistSongsStreamHandler: Error at item $itemCount (${e.message})", e)
                if (itemCount == 0) throw e
                continue
            }
        }

        Log.d("YTMusicAPI", "ArtistSongsStreamHandler: Finished processing $itemCount items")
    }

    override fun onCancel(arguments: Any?) {
        Log.d("YTMusicAPI", "ArtistSongsStreamHandler: onCancel called")
        job?.cancel()
        searchId?.let {
            if (plugin.searchManager.has(it)) {
                plugin.searchManager.cancelSearch(it)
            } else {
                Log.d("YTMusicAPI", "Nothing to cancel for $it")
            }
        }
        eventSink = null

        synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown }?.shutdown()
            pythonExecutor = null
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class RadioStreamHandler(private val plugin: YtFlutterMusicapiPlugin) : EventChannel.StreamHandler {

    companion object {
        const val SEARCH_TYPE = "RADIO"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var searchId: String? = null
    private var job: Job? = null
    private var pythonExecutor: ExecutorService? = null
    private val executorLock = Object()

    private fun getOrCreateExecutor(): ExecutorService {
        return synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown && !it.isTerminated } ?: run {
                Executors.newSingleThreadExecutor { r ->
                    Thread(r, "PythonExecutor-Radio").apply { isDaemon = true }
                }.also { pythonExecutor = it }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val args = arguments as? Map<*, *> ?: run {
            events?.error("INVALID_ARGUMENTS", "Arguments must be a map", null)
            return
        }

        job = plugin.coroutineScope.launch {
            try {
                Log.d("YTMusicAPI", "RadioStreamHandler: Starting radio execution")
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Listening on searchId = $searchId")

                val videoId = args["videoId"] as? String ?: throw IllegalArgumentException("videoId required")
                searchId = "radio_${videoId.hashCode()}_${System.currentTimeMillis()}"

                val limit = args["limit"] as? Int ?: 100
                val thumbQuality = args["thumbQuality"] as? String ?: "VERY_HIGH"
                val audioQuality = args["audioQuality"] as? String ?: "HIGH"
                val includeAudioUrl = args["includeAudioUrl"] as? Boolean ?: true
                val includeAlbumArt = args["includeAlbumArt"] as? Boolean ?: true

                plugin.searchManager.cancelType(SEARCH_TYPE)

                val searcher = plugin.getMusicSearcher() ?: throw IllegalStateException("Music searcher unavailable")

                Log.d("YTMusicAPI", "RadioStreamHandler: Creating generator for videoId: $videoId")

                val generator = suspendCancellableCoroutine<PyObject> { continuation ->
                    val executor = getOrCreateExecutor()
                    try {
                        executor.execute {
                            try {
                                val result = searcher.callAttr(
                                    "get_radio",
                                    videoId,
                                    limit,
                                    thumbQuality,
                                    audioQuality,
                                    includeAudioUrl,
                                    includeAlbumArt
                                )
                                continuation.resume(result)
                            } catch (e: Exception) {
                                continuation.resumeWithException(e)
                            }
                        }
                    } catch (e: Exception) {
                        continuation.resumeWithException(e)
                    }

                    continuation.invokeOnCancellation {
                        Log.d("YTMusicAPI", "RadioStreamHandler: Generator creation cancelled")
                    }
                }

                plugin.searchManager.registerSearch(searchId!!, SEARCH_TYPE, generator, job!!)

                Log.d("YTMusicAPI", "RadioStreamHandler: Starting iteration")
                processRadioResults(generator, events, limit)

                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.endOfStream()
                    }
                }

            } catch (e: TimeoutCancellationException) {
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("TIMEOUT_ERROR", "Radio request timed out", null)
                    }
                }
            } catch (e: CancellationException) {
                Log.d("YTMusicAPI", "RadioStreamHandler: Search cancelled")
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "RadioStreamHandler: Stream error", e)
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("STREAM_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            } finally {
                searchId?.let {
                    if (plugin.searchManager.has(it)) {
                        plugin.searchManager.cancelSearch(it)
                    }
                }
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Cleaning up searchId = $searchId (job=${job?.isCancelled})")

                withContext(Dispatchers.Main.immediate) {
                    eventSink?.endOfStream()
                }
            }
        }
    }

    private suspend fun processRadioResults(generator: PyObject, events: EventChannel.EventSink?, limit: Int) {
        var itemCount = 0
        val cancelled = AtomicBoolean(false)
        val iterator = generator.callAttr("__iter__")

        while (
            plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE) &&
            itemCount < limit &&
            !cancelled.get()
        ) {
            try {
                Log.d("YTMusicAPI", "RadioStreamHandler: Getting radio track $itemCount")

                val item = withTimeoutOrNull(20000L) {
                    suspendCancellableCoroutine<PyObject?> { continuation ->
                        val executor = getOrCreateExecutor()
                        try {
                            executor.execute {
                                try {
                                    val result = iterator.callAttr("__next__")
                                    continuation.resume(result)
                                } catch (e: Exception) {
                                    if (e.message?.contains("StopIteration") == true) {
                                        continuation.resume(null)
                                    } else {
                                        continuation.resumeWithException(e)
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }

                        continuation.invokeOnCancellation {
                            cancelled.set(true)
                        }
                    }
                }

                if (item == null || item.isNone) {
                    Log.d("YTMusicAPI", "RadioStreamHandler: No more radio tracks")
                    break
                }

                val trackData = plugin.convertPythonDictToMap(item)
                Log.d("YTMusicAPI", "RadioStreamHandler: Processing radio track: ${trackData["title"]}")

                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.success(
                            mapOf(
                                "title" to (trackData["title"]?.toString() ?: "Unknown"),
                                "artists" to (trackData["artists"]?.toString() ?: "Unknown"),
                                "videoId" to (trackData["videoId"]?.toString() ?: ""),
                                "duration" to (trackData["duration"]?.toString() ?: ""),
                                "albumArt" to (trackData["albumArt"]?.toString() ?: ""),
                                "audioUrl" to (trackData["audioUrl"]?.toString() ?: ""),
                                "artistName" to (trackData["artist_name"]?.toString() ?: "Unknown"),
                                "year" to (trackData["year"]?.toString() ?: "")
                            )
                        )
                    } else {
                        Log.d("YTMusicAPI", "⚠️ Skipped radio result for stale search: $searchId")
                    }
                }

                itemCount++
                Log.d("YTMusicAPI", "RadioStreamHandler: Processed $itemCount radio tracks")

                yield()

            } catch (e: Exception) {
                Log.e("YTMusicAPI", "RadioStreamHandler: Error at radio track $itemCount (${e.message})", e)
                if (itemCount == 0) throw e
                continue
            }
        }

        Log.d("YTMusicAPI", "RadioStreamHandler: Finished processing $itemCount radio tracks")
    }

    override fun onCancel(arguments: Any?) {
        Log.d("YTMusicAPI", "RadioStreamHandler: onCancel called")
        job?.cancel()
        searchId?.let {
            if (plugin.searchManager.has(it)) {
                plugin.searchManager.cancelSearch(it)
            } else {
                Log.d("YTMusicAPI", "Nothing to cancel for $it")
            }
        }
        eventSink = null

        synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown }?.shutdown()
            pythonExecutor = null
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ChartsStreamHandler(private val plugin: YtFlutterMusicapiPlugin) : EventChannel.StreamHandler {

    companion object {
        const val SEARCH_TYPE = "charts"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var searchId: String? = null
    private var job: Job? = null
    private var pythonExecutor: ExecutorService? = null
    private val executorLock = Object()

    private fun getOrCreateExecutor(): ExecutorService {
        return synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown && !it.isTerminated } ?: run {
                Executors.newSingleThreadExecutor { r ->
                    Thread(r, "PythonExecutor-Charts").apply { isDaemon = true }
                }.also { pythonExecutor = it }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val args = arguments as? Map<*, *> ?: run {
            events?.error("INVALID_ARGUMENTS", "Arguments must be a map", null)
            return
        }

        job = plugin.coroutineScope.launch {
            try {
                Log.d("YTMusicAPI", "ChartsStreamHandler: Starting charts execution")
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Listening on searchId = $searchId")

                val country = args["country"] as? String ?: "ZZ"
                searchId = "charts_${country.hashCode()}_${System.currentTimeMillis()}"

                val limit = args["limit"] as? Int ?: 50
                val thumbQuality = args["thumbQuality"] as? String ?: "VERY_HIGH"
                val audioQuality = args["audioQuality"] as? String ?: "HIGH"
                val includeAudioUrl = args["includeAudioUrl"] as? Boolean ?: true
                val includeAlbumArt = args["includeAlbumArt"] as? Boolean ?: true

                plugin.searchManager.cancelType(SEARCH_TYPE)

                val searcher = plugin.getMusicSearcher() ?: throw IllegalStateException("Music searcher unavailable")

                Log.d("YTMusicAPI", "ChartsStreamHandler: Creating generator for country: $country")

                val generator = suspendCancellableCoroutine<PyObject> { continuation ->
                    val executor = getOrCreateExecutor()
                    try {
                        executor.execute {
                            try {
                                val result = searcher.callAttr(
                                    "get_charts",
                                    country,
                                    limit,
                                    thumbQuality,
                                    audioQuality,
                                    includeAudioUrl,
                                    includeAlbumArt
                                )
                                continuation.resume(result)
                            } catch (e: Exception) {
                                continuation.resumeWithException(e)
                            }
                        }
                    } catch (e: Exception) {
                        continuation.resumeWithException(e)
                    }

                    continuation.invokeOnCancellation {
                        Log.d("YTMusicAPI", "ChartsStreamHandler: Generator creation cancelled")
                    }
                }

                plugin.searchManager.registerSearch(searchId!!, SEARCH_TYPE, generator, job!!)

                Log.d("YTMusicAPI", "ChartsStreamHandler: Starting iteration")
                processChartsResults(generator, events, limit, country)

                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.endOfStream()
                    }
                }

            } catch (e: TimeoutCancellationException) {
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("TIMEOUT_ERROR", "Charts request timed out", null)
                    }
                }
            } catch (e: CancellationException) {
                Log.d("YTMusicAPI", "ChartsStreamHandler: Search cancelled")
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "ChartsStreamHandler: Stream error", e)
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("STREAM_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            } finally {
                searchId?.let {
                    if (plugin.searchManager.has(it)) {
                        plugin.searchManager.cancelSearch(it)
                    }
                }
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Cleaning up searchId = $searchId (job=${job?.isCancelled})")

                withContext(Dispatchers.Main.immediate) {
                    eventSink?.endOfStream()
                }
            }
        }
    }

    private suspend fun processChartsResults(generator: PyObject, events: EventChannel.EventSink?, limit: Int, country: String) {
        var itemCount = 0
        val cancelled = AtomicBoolean(false)
        val iterator = generator.callAttr("__iter__")

        while (
            plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE) &&
            itemCount < limit &&
            !cancelled.get()
        ) {
            try {
                Log.d("YTMusicAPI", "ChartsStreamHandler: Getting item $itemCount")

                val item = withTimeoutOrNull(20000L) {
                    suspendCancellableCoroutine<PyObject?> { continuation ->
                        val executor = getOrCreateExecutor()
                        try {
                            executor.execute {
                                try {
                                    val result = iterator.callAttr("__next__")
                                    continuation.resume(result)
                                } catch (e: Exception) {
                                    if (e.message?.contains("StopIteration") == true) {
                                        continuation.resume(null)
                                    } else {
                                        continuation.resumeWithException(e)
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }

                        continuation.invokeOnCancellation {
                            cancelled.set(true)
                        }
                    }
                }

                if (item == null || item.isNone) {
                    Log.d("YTMusicAPI", "ChartsStreamHandler: No more items")
                    break
                }

                val chartData = plugin.convertPythonDictToMap(item)
                Log.d("YTMusicAPI", "ChartsStreamHandler: Processing: ${chartData["title"]} (${chartData["chart_type"]})")

                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.success(
                            mapOf(
                                "title" to (chartData["title"]?.toString() ?: "Unknown"),
                                "artists" to (chartData["artists"]?.toString() ?: "Unknown"),
                                "videoId" to (chartData["videoId"]?.toString() ?: ""),
                                "duration" to (chartData["duration"]?.toString() ?: ""),
                                "albumArt" to (chartData["albumArt"]?.toString() ?: ""),
                                "audioUrl" to (chartData["audioUrl"]?.toString() ?: ""),
                                "country" to country,
                                "chartType" to (chartData["chart_type"]?.toString() ?: "unknown"),
                                "rank" to (chartData["rank"]?.toString() ?: ""),
                                "trend" to (chartData["trend"]?.toString() ?: "neutral"),
                                "views" to (chartData["views"]?.toString() ?: ""),
                                "isExplicit" to (chartData["isExplicit"] as? Boolean ?: false),
                                "playlistId" to (chartData["playlistId"]?.toString() ?: ""),
                                "album" to (chartData["album"] ?: mapOf<String, Any>())
                            )
                        )
                    } else {
                        Log.d("YTMusicAPI", "⚠️ Skipped result for stale search: $searchId")
                    }
                }

                itemCount++
                Log.d("YTMusicAPI", "ChartsStreamHandler: Processed $itemCount items")

                yield()

            } catch (e: Exception) {
                Log.e("YTMusicAPI", "ChartsStreamHandler: Error at item $itemCount (${e.message})", e)
                if (itemCount == 0) throw e
                continue
            }
        }

        Log.d("YTMusicAPI", "ChartsStreamHandler: Finished processing $itemCount items")
    }

    override fun onCancel(arguments: Any?) {
        Log.d("YTMusicAPI", "ChartsStreamHandler: onCancel called")
        job?.cancel()
        searchId?.let {
            if (plugin.searchManager.has(it)) {
                plugin.searchManager.cancelSearch(it)
            } else {
                Log.d("YTMusicAPI", "Nothing to cancel for $it")
            }
        }
        eventSink = null

        synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown }?.shutdown()
            pythonExecutor = null
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ArtistAlbumsStreamHandler(private val plugin: YtFlutterMusicapiPlugin) : EventChannel.StreamHandler {

    companion object {
        const val SEARCH_TYPE = "ARTIST_ALBUMS"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var searchId: String? = null
    private var job: Job? = null
    private var pythonExecutor: ExecutorService? = null
    private val executorLock = Object()

    private fun getOrCreateExecutor(): ExecutorService {
        return synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown && !it.isTerminated } ?: run {
                Executors.newSingleThreadExecutor { r ->
                    Thread(r, "PythonExecutor-ArtistAlbums").apply { isDaemon = true }
                }.also { pythonExecutor = it }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val args = arguments as? Map<*, *> ?: run {
            events?.error("INVALID_ARGUMENTS", "Arguments must be a map", null)
            return
        }

        job = plugin.coroutineScope.launch {
            try {
                Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: Starting artist albums execution")
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Listening on searchId = $searchId")

                val artistName = args["artistName"] as? String ?: throw IllegalArgumentException("artistName required")
                searchId = "artist_albums_${artistName.hashCode()}_${System.currentTimeMillis()}"

                // Updated parameters to match new Python implementation
                val maxAlbums = args["maxAlbums"] as? Int ?: 5
                val maxSongsPerAlbum = args["maxSongsPerAlbum"] as? Int ?: 10
                val thumbQuality = args["thumbQuality"] as? String ?: "VERY_HIGH"
                val audioQuality = args["audioQuality"] as? String ?: "HIGH"
                val includeAudioUrl = args["includeAudioUrl"] as? Boolean ?: true
                val includeAlbumArt = args["includeAlbumArt"] as? Boolean ?: true
                val maxWorkers = args["maxWorkers"] as? Int ?: 5

                plugin.searchManager.cancelType(SEARCH_TYPE)

                val searcher = plugin.getMusicSearcher() ?: throw IllegalStateException("Music searcher unavailable")

                Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: Creating generator for: $artistName (maxAlbums=$maxAlbums, maxSongs=$maxSongsPerAlbum, workers=$maxWorkers)")

                val generator = suspendCancellableCoroutine<PyObject> { continuation ->
                    val executor = getOrCreateExecutor()
                    try {
                        executor.execute {
                            try {
                                val result = searcher.callAttr(
                                    "get_artist_albums",
                                    artistName,
                                    maxAlbums,
                                    maxSongsPerAlbum,
                                    thumbQuality,
                                    audioQuality,
                                    includeAudioUrl,
                                    includeAlbumArt,
                                    maxWorkers
                                )
                                continuation.resume(result)
                            } catch (e: Exception) {
                                continuation.resumeWithException(e)
                            }
                        }
                    } catch (e: Exception) {
                        continuation.resumeWithException(e)
                    }

                    continuation.invokeOnCancellation {
                        Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: Generator creation cancelled")
                    }
                }

                plugin.searchManager.registerSearch(searchId!!, SEARCH_TYPE, generator, job!!)

                Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: Starting iteration")
                processAlbumsResults(generator, events, maxAlbums, artistName)

                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.endOfStream()
                    }
                }

            } catch (e: TimeoutCancellationException) {
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("TIMEOUT_ERROR", "Artist albums request timed out", null)
                    }
                }
            } catch (e: CancellationException) {
                Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: Search cancelled")
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "ArtistAlbumsStreamHandler: Stream error", e)
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("STREAM_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            } finally {
                searchId?.let {
                    if (plugin.searchManager.has(it)) {
                        plugin.searchManager.cancelSearch(it)
                    }
                }
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Cleaning up searchId = $searchId (job=${job?.isCancelled})")

                withContext(Dispatchers.Main.immediate) {
                    eventSink?.endOfStream()
                }
            }
        }
    }

    private suspend fun processAlbumsResults(generator: PyObject, events: EventChannel.EventSink?, maxAlbums: Int, artistName: String) {
        var albumCount = 0
        val cancelled = AtomicBoolean(false)
        val iterator = generator.callAttr("__iter__")
        val albumsWithTracks = mutableMapOf<String, MutableMap<String, Any>>()

        while (
            plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE) &&
            albumCount < maxAlbums &&
            !cancelled.get()
        ) {
            try {
                Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: Getting next item")

                val item = withTimeoutOrNull(45000L) { // Extended timeout for worker processing
                    suspendCancellableCoroutine<PyObject?> { continuation ->
                        val executor = getOrCreateExecutor()
                        try {
                            executor.execute {
                                try {
                                    val result = iterator.callAttr("__next__")
                                    continuation.resume(result)
                                } catch (e: Exception) {
                                    if (e.message?.contains("StopIteration") == true) {
                                        continuation.resume(null)
                                    } else {
                                        continuation.resumeWithException(e)
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }

                        continuation.invokeOnCancellation {
                            cancelled.set(true)
                        }
                    }
                }

                if (item == null || item.isNone) {
                    Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: No more items")
                    break
                }

                val albumData = plugin.convertPythonDictToMap(item)
                val albumTitle = albumData["title"]?.toString() ?: "Unknown Album"
                
                Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: Processing item: $albumTitle")

                // Check if this is an album info (empty tracks) or album with tracks
                val tracks = albumData["tracks"] as? List<*> ?: emptyList<Any>()
                
                if (tracks.isEmpty()) {
                    // This is album info - store it and send immediately
                    val albumInfo = mutableMapOf(
                        "type" to "album",
                        "title" to albumTitle,
                        "artist" to artistName,
                        "year" to (albumData["year"]?.toString() ?: ""),
                        "albumArt" to (albumData["albumArt"]?.toString() ?: ""),
                        "tracks" to mutableListOf<Map<String, Any>>()
                    )
                    
                    albumsWithTracks[albumTitle] = albumInfo
                    albumCount++
                    
                    withContext(Dispatchers.Main) {
                        if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                            events?.success(albumInfo.toMap())
                            Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: Sent album info for: $albumTitle")
                        }
                    }
                } else {
                    // This is an updated album with tracks - update the stored album
                    val tracksData = tracks.mapNotNull { track ->
                        if (track is Map<*, *>) {
                            mapOf(
                                "title" to (track["title"]?.toString() ?: "Unknown"),
                                "artists" to (track["artists"]?.toString() ?: "Unknown"),
                                "videoId" to (track["videoId"]?.toString() ?: ""),
                                "duration" to (track["duration"]?.toString() ?: ""),
                                "albumArt" to (track["albumArt"]?.toString() ?: ""),
                                "audioUrl" to (track["audioUrl"]?.toString() ?: ""),
                                "artistName" to (track["artist_name"]?.toString() ?: artistName),
                                "year" to (track["year"]?.toString() ?: "")
                            )
                        } else null
                    }

                    // Update existing album with new tracks
                    albumsWithTracks[albumTitle]?.let { storedAlbum ->
                        val currentTracks = storedAlbum["tracks"] as? MutableList<Map<String, Any>> ?: mutableListOf()
                        currentTracks.addAll(tracksData)
                        storedAlbum["tracks"] = currentTracks // ensure it remains mutable

                        withContext(Dispatchers.Main) {
                            if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                                events?.success(storedAlbum.toMap())
                                Log.d("YTMusicAPI", "Updated album $albumTitle with ${tracksData.size} tracks (total: ${currentTracks.size})")
                            }
                        }
                    }

                }

                yield()

            } catch (e: Exception) {
                Log.e("YTMusicAPI", "ArtistAlbumsStreamHandler: Error processing item (${e.message})", e)
                if (albumCount == 0) throw e
                continue
            }
        }

        Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: Finished processing $albumCount albums")
    }

    override fun onCancel(arguments: Any?) {
        Log.d("YTMusicAPI", "ArtistAlbumsStreamHandler: onCancel called")
        job?.cancel()
        searchId?.let {
            if (plugin.searchManager.has(it)) {
                plugin.searchManager.cancelSearch(it)
            } else {
                Log.d("YTMusicAPI", "Nothing to cancel for $it")
            }
        }
        eventSink = null

        synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown }?.shutdown()
            pythonExecutor = null
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ArtistSinglesStreamHandler(private val plugin: YtFlutterMusicapiPlugin) : EventChannel.StreamHandler {

    companion object {
        const val SEARCH_TYPE = "ARTIST_SINGLES"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var searchId: String? = null
    private var job: Job? = null
    private var pythonExecutor: ExecutorService? = null
    private val executorLock = Object()

    private fun getOrCreateExecutor(): ExecutorService {
        return synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown && !it.isTerminated } ?: run {
                Executors.newSingleThreadExecutor { r ->
                    Thread(r, "PythonExecutor-ArtistSingles").apply { isDaemon = true }
                }.also { pythonExecutor = it }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val args = arguments as? Map<*, *> ?: run {
            events?.error("INVALID_ARGUMENTS", "Arguments must be a map", null)
            return
        }

        job = plugin.coroutineScope.launch {
            try {
                Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Starting artist singles execution")
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Listening on searchId = $searchId")

                val artistName = args["artistName"] as? String ?: throw IllegalArgumentException("artistName required")
                searchId = "artist_singles_${artistName.hashCode()}_${System.currentTimeMillis()}"

                // Updated parameters to match new Python implementation
                val maxSingles = args["maxSingles"] as? Int ?: 5
                val maxSongsPerSingle = args["maxSongsPerSingle"] as? Int ?: 10
                val thumbQuality = args["thumbQuality"] as? String ?: "VERY_HIGH"
                val audioQuality = args["audioQuality"] as? String ?: "HIGH"
                val includeAudioUrl = args["includeAudioUrl"] as? Boolean ?: true
                val includeAlbumArt = args["includeAlbumArt"] as? Boolean ?: true
                val maxWorkers = args["maxWorkers"] as? Int ?: 5

                plugin.searchManager.cancelType(SEARCH_TYPE)

                val searcher = plugin.getMusicSearcher() ?: throw IllegalStateException("Music searcher unavailable")

                Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Creating generator for: $artistName (maxSingles=$maxSingles, maxSongs=$maxSongsPerSingle, workers=$maxWorkers)")

                val generator = suspendCancellableCoroutine<PyObject> { continuation ->
                    val executor = getOrCreateExecutor()
                    try {
                        executor.execute {
                            try {
                                val result = searcher.callAttr(
                                    "get_artist_singles_eps",
                                    artistName,
                                    maxSingles,
                                    maxSongsPerSingle,
                                    thumbQuality,
                                    audioQuality,
                                    includeAudioUrl,
                                    includeAlbumArt,
                                    maxWorkers
                                )
                                continuation.resume(result)
                            } catch (e: Exception) {
                                continuation.resumeWithException(e)
                            }
                        }
                    } catch (e: Exception) {
                        continuation.resumeWithException(e)
                    }

                    continuation.invokeOnCancellation {
                        Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Generator creation cancelled")
                    }
                }

                plugin.searchManager.registerSearch(searchId!!, SEARCH_TYPE, generator, job!!)

                Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Starting iteration")
                processSinglesResults(generator, events, maxSingles, artistName)

                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.endOfStream()
                    }
                }

            } catch (e: TimeoutCancellationException) {
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("TIMEOUT_ERROR", "Artist singles request timed out", null)
                    }
                }
            } catch (e: CancellationException) {
                Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Search cancelled")
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "ArtistSinglesStreamHandler: Stream error", e)
                withContext(Dispatchers.Main) {
                    if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                        events?.error("STREAM_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            } finally {
                searchId?.let {
                    if (plugin.searchManager.has(it)) {
                        plugin.searchManager.cancelSearch(it)
                    }
                }
                Log.d("YTMusicAPI", "[$SEARCH_TYPE] Cleaning up searchId = $searchId (job=${job?.isCancelled})")

                withContext(Dispatchers.Main.immediate) {
                    eventSink?.endOfStream()
                }
            }
        }
    }

    private suspend fun processSinglesResults(generator: PyObject, events: EventChannel.EventSink?, maxSingles: Int, artistName: String) {
        var singleCount = 0
        val cancelled = AtomicBoolean(false)
        val iterator = generator.callAttr("__iter__")
        val singlesWithTracks = mutableMapOf<String, MutableMap<String, Any>>()

        while (
            plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE) &&
            singleCount < maxSingles &&
            !cancelled.get()
        ) {
            try {
                Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Getting next item")

                val item = withTimeoutOrNull(45000L) { // Extended timeout for worker processing
                    suspendCancellableCoroutine<PyObject?> { continuation ->
                        val executor = getOrCreateExecutor()
                        try {
                            executor.execute {
                                try {
                                    val result = iterator.callAttr("__next__")
                                    continuation.resume(result)
                                } catch (e: Exception) {
                                    if (e.message?.contains("StopIteration") == true) {
                                        continuation.resume(null)
                                    } else {
                                        continuation.resumeWithException(e)
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            continuation.resumeWithException(e)
                        }

                        continuation.invokeOnCancellation {
                            cancelled.set(true)
                        }
                    }
                }

                if (item == null || item.isNone) {
                    Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: No more items")
                    break
                }

                val singleData = plugin.convertPythonDictToMap(item)
                val singleTitle = singleData["title"]?.toString() ?: "Unknown Single/EP"
                
                Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Processing item: $singleTitle")

                // Check if this is single info (empty tracks) or single with tracks
                val tracks = singleData["tracks"] as? List<*> ?: emptyList<Any>()
                
                if (tracks.isEmpty()) {
                    // This is single info - store it and send immediately
                    val singleInfo = mutableMapOf(
                        "type" to "single",
                        "title" to singleTitle,
                        "artist" to artistName,
                        "year" to (singleData["year"]?.toString() ?: ""),
                        "albumArt" to (singleData["albumArt"]?.toString() ?: ""),
                        "tracks" to mutableListOf<Map<String, Any>>()
                    )
                    
                    singlesWithTracks[singleTitle] = singleInfo
                    singleCount++
                    
                    withContext(Dispatchers.Main) {
                        if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                            events?.success(singleInfo.toMap())
                            Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Sent single info for: $singleTitle")
                        }
                    }
                } else {
                    // This is an updated single with tracks - update the stored single
                    val tracksData = tracks.mapNotNull { track ->
                        if (track is Map<*, *>) {
                            mapOf(
                                "title" to (track["title"]?.toString() ?: "Unknown"),
                                "artists" to (track["artists"]?.toString() ?: "Unknown"),
                                "videoId" to (track["videoId"]?.toString() ?: ""),
                                "duration" to (track["duration"]?.toString() ?: ""),
                                "albumArt" to (track["albumArt"]?.toString() ?: ""),
                                "audioUrl" to (track["audioUrl"]?.toString() ?: ""),
                                "artistName" to (track["artist_name"]?.toString() ?: artistName),
                                "year" to (track["year"]?.toString() ?: "")
                            )
                        } else null
                    }

                    // Update existing single with new tracks
                    singlesWithTracks[singleTitle]?.let { storedSingle ->
                        val currentTracks = storedSingle["tracks"] as MutableList<Map<String, Any>>
                        currentTracks.addAll(tracksData)
                        
                        withContext(Dispatchers.Main) {
                            if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
                                events?.success(storedSingle.toMap())
                                Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Updated single $singleTitle with ${tracksData.size} tracks (total: ${currentTracks.size})")
                            }
                        }
                    }
                }

                yield()

            } catch (e: Exception) {
                Log.e("YTMusicAPI", "ArtistSinglesStreamHandler: Error processing item (${e.message})", e)
                if (singleCount == 0) throw e
                continue
            }
        }

        Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: Finished processing $singleCount singles/EPs")
    }

    override fun onCancel(arguments: Any?) {
        Log.d("YTMusicAPI", "ArtistSinglesStreamHandler: onCancel called")
        job?.cancel()
        searchId?.let {
            if (plugin.searchManager.has(it)) {
                plugin.searchManager.cancelSearch(it)
            } else {
                Log.d("YTMusicAPI", "Nothing to cancel for $it")
            }
        }
        eventSink = null

        synchronized(executorLock) {
            pythonExecutor?.takeIf { !it.isShutdown }?.shutdown()
            pythonExecutor = null
        }
    }
}



// Audio Not working cause of YT Rate Limit failed method

// @OptIn(ExperimentalCoroutinesApi::class)
// class BatchSongsStreamHandler(private val plugin: YtFlutterMusicapiPlugin) : EventChannel.StreamHandler {
//     companion object {
//         const val SEARCH_TYPE = "batch_songs"
//         private const val BASE_TIMEOUT = 20000L
//         private const val MAX_RETRIES = 3
//         private const val RETRY_DELAY_BASE = 1000L
//         private const val MEMORY_CLEANUP_INTERVAL = 50
//     }
    
//     private var eventSink: EventChannel.EventSink? = null
//     private var searchId: String? = null
//     private var job: Job? = null
//     private var pythonExecutor: ExecutorService? = null
//     private val executorLock = Object()
    
//     // Memory management
//     private val processedResults = mutableSetOf<Int>()
//     private var lastCleanupTime = System.currentTimeMillis()
    
//     private fun getOrCreateExecutor(): ExecutorService {
//         return synchronized(executorLock) {
//             pythonExecutor?.takeIf { !it.isShutdown && !it.isTerminated } ?: run {
//                 Executors.newSingleThreadExecutor { r ->
//                     Thread(r, "PythonExecutor-Batch").apply { 
//                         isDaemon = true
//                         priority = Thread.NORM_PRIORITY + 1 // Slightly higher priority
//                     }
//                 }.also { pythonExecutor = it }
//             }
//         }
//     }
    
//     private fun cleanupMemory() {
//         if (processedResults.size >= MEMORY_CLEANUP_INTERVAL || 
//             System.currentTimeMillis() - lastCleanupTime > 30000L) {
            
//             processedResults.clear()
//             lastCleanupTime = System.currentTimeMillis()
//             System.gc() // Suggest garbage collection
//             Log.d("YTMusicAPI", "BatchSongsStreamHandler: Memory cleanup performed")
//         }
//     }

//     override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
//         eventSink = events
//         val args = arguments as? Map<*, *> ?: run {
//             events?.error("INVALID_ARGUMENTS", "Arguments must be a map", null)
//             return
//         }

//         job = plugin.coroutineScope.launch {
//             try {
//                 Log.d("YTMusicAPI", "BatchSongsStreamHandler: Starting batch processing")
                
//                 // Validate and parse input with better error handling
//                 val songs = when (val songsArg = args["songs"]) {
//                     is List<*> -> {
//                         songsArg.mapIndexedNotNull { index, songItem ->
//                             when (songItem) {
//                                 is Map<*, *> -> {
//                                     val songName = songItem["song_name"] as? String
//                                     val artistName = songItem["artist_name"] as? String
                                    
//                                     if (songName.isNullOrBlank() || artistName.isNullOrBlank()) {
//                                         Log.w("YTMusicAPI", "Invalid song at index $index: songName='$songName', artistName='$artistName'")
//                                         null
//                                     } else {
//                                         mapOf(
//                                             "song_name" to songName.trim(),
//                                             "artist_name" to artistName.trim()
//                                         )
//                                     }
//                                 }
//                                 else -> {
//                                     Log.w("YTMusicAPI", "Invalid song format at index $index: $songItem")
//                                     null
//                                 }
//                             }
//                         }
//                     }
//                     else -> emptyList()
//                 }
                
//                 if (songs.isEmpty()) {
//                     throw IllegalArgumentException("No valid songs found. Songs must contain 'song_name' and 'artist_name' fields")
//                 }
                
//                 val batchSize = (args["batchSize"] as? Int)?.coerceIn(1, 100) ?: 30
//                 val thumbQuality = args["thumbQuality"] as? String ?: "VERY_HIGH"
//                 val audioQuality = args["audioQuality"] as? String ?: "HIGH"
               
//                 searchId = "batch_${songs.hashCode()}_${System.currentTimeMillis()}"
//                 plugin.searchManager.cancelType(SEARCH_TYPE)
                
//                 Log.d("YTMusicAPI", "[$SEARCH_TYPE] Processing ${songs.size} songs in batches of $batchSize")

//                 val searcher = plugin.getMusicSearcher() 
//                     ?: throw IllegalStateException("Music searcher not initialized")
                
//                 // Create Python generator with improved error handling
//                 val generator = withContext(Dispatchers.IO) {
//                     withTimeoutOrNull(30000L) { // 30 second timeout for generator creation
//                         suspendCancellableCoroutine<PyObject> { continuation ->
//                             val executor = getOrCreateExecutor()
                            
//                             continuation.invokeOnCancellation {
//                                 Log.d("YTMusicAPI", "BatchSongsStreamHandler: Generator creation cancelled")
//                             }
                            
//                             try {
//                                 executor.execute {
//                                     try {
//                                         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Creating Python generator")
                                        
//                                         // Convert Kotlin list to Python list of dicts with validation
//                                         val pythonInstance = plugin.getPythonInstance()
//                                             ?: throw IllegalStateException("Python instance not available")
                                        
//                                         val pySongs = pythonInstance.getBuiltins().callAttr("list") 
//                                             ?: throw IllegalStateException("Python builtins not available")
                                        
//                                         for ((index, song) in songs.withIndex()) {
//                                             try {
//                                                 val pySong = pythonInstance.getBuiltins().callAttr("dict") 
//                                                     ?: continue
//                                                 pySong.callAttr("__setitem__", "song_name", song["song_name"] ?: "")
//                                                 pySong.callAttr("__setitem__", "artist_name", song["artist_name"] ?: "")
//                                                 pySongs.callAttr("append", pySong)
//                                                 Log.v("YTMusicAPI", "BatchSongsStreamHandler: Added song $index to Python list")
//                                             } catch (e: Exception) {
//                                                 Log.w("YTMusicAPI", "Failed to add song at index $index: ${e.message}")
//                                             }
//                                         }

//                                         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Calling process_batch_songs")
//                                         val result = searcher.callAttr(
//                                             "process_batch_songs",
//                                             pySongs,
//                                             batchSize,
//                                             plugin.getPythonThumbnailQuality(thumbQuality),
//                                             plugin.getPythonAudioQuality(audioQuality),
//                                         )
//                                         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Python generator created successfully")
//                                         continuation.resume(result)
//                                     } catch (e: Exception) {
//                                         Log.e("YTMusicAPI", "Error creating Python generator", e)
//                                         continuation.resumeWithException(e)
//                                     }
//                                 }
//                             } catch (e: Exception) {
//                                 Log.e("YTMusicAPI", "Error submitting generator creation task", e)
//                                 continuation.resumeWithException(e)
//                             }
//                         }
//                     } ?: throw Exception("Generator creation timed out after 30 seconds")
//                 }

//                 plugin.searchManager.registerSearch(searchId!!, SEARCH_TYPE, generator, job!!)
//                 processBatchResults(generator, events, songs.size)
                
//                 withContext(Dispatchers.Main) {
//                     if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
//                         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Sending endOfStream")
//                         events?.endOfStream()
//                     }
//                 }
                
//             } catch (e: Exception) {
//                 when {
//                     e.message?.contains("timed out") == true -> {
//                         Log.e("YTMusicAPI", "BatchSongsStreamHandler: Overall timeout", e)
//                         withContext(Dispatchers.Main) {
//                             searchId?.let { id ->
//                                 if (plugin.searchManager.isLatestOfType(id, SEARCH_TYPE)) {
//                                     events?.error("TIMEOUT_ERROR", "Batch processing timed out: ${e.message}", null)
//                                 }
//                             }
//                         }
//                     }
//                     e is CancellationException -> {
//                         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Processing cancelled")
//                         // Don't treat cancellation as an error
//                     }
//                     else -> {
//                         Log.e("YTMusicAPI", "BatchSongsStreamHandler: Stream error", e)
//                         withContext(Dispatchers.Main) {
//                             searchId?.let { id ->
//                                 if (plugin.searchManager.isLatestOfType(id, SEARCH_TYPE)) {
//                                     events?.error("STREAM_ERROR", e.message ?: "Unknown error occurred", null)
//                                 }
//                             }
//                         }
//                     }
//                 }
//             } finally {
//                 cleanup()
//             }
//         }
//     }

//     private suspend fun processBatchResults(
//         generator: PyObject,
//         events: EventChannel.EventSink?,
//         totalSongs: Int
//     ) {
//         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Starting to process batch results for $totalSongs songs")
        
//         val iterator = try {
//             generator.callAttr("__iter__")
//         } catch (e: Exception) {
//             Log.e("YTMusicAPI", "BatchSongsStreamHandler: Error creating iterator", e)
//             throw e
//         }
        
//         var albumArtCount = 0        // Count album_art events
//         var songCompleteCount = 0    // Count song_complete events  
//         var retryCount = 0
//         val cancelled = AtomicBoolean(false)
//         var consecutiveErrors = 0
//         val maxConsecutiveErrors = 5
//         var itemsFetched = 0
        
//         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Iterator created, starting processing loop")
        
//         // Continue until we get all song_complete events OR we've tried long enough
//         while (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE) && 
//             songCompleteCount < totalSongs &&  // ← FIXED: Count only complete songs
//             !cancelled.get() &&
//             consecutiveErrors < maxConsecutiveErrors) {
            
//             try {
//                 val dynamicTimeout = BASE_TIMEOUT + (retryCount * 5000L)
//                 Log.v("YTMusicAPI", "BatchSongsStreamHandler: Attempting to fetch next item (timeout: ${dynamicTimeout}ms, attempt: ${itemsFetched + 1})")
                
//                 val item = withTimeoutOrNull(dynamicTimeout) {
//                     suspendCancellableCoroutine<PyObject?> { continuation ->
//                         val executor = getOrCreateExecutor()
                        
//                         continuation.invokeOnCancellation {
//                             cancelled.set(true)
//                             Log.d("YTMusicAPI", "BatchSongsStreamHandler: Item processing cancelled")
//                         }
                        
//                         try {
//                             executor.execute {
//                                 try {
//                                     Log.v("YTMusicAPI", "BatchSongsStreamHandler: Calling Python iterator.__next__()")
//                                     val result = iterator.callAttr("__next__")
//                                     val isValidResult = result != null && !result.isNone
//                                     Log.v("YTMusicAPI", "BatchSongsStreamHandler: Python iterator returned result: $isValidResult")
//                                     continuation.resume(result)
//                                 } catch (e: Exception) {
//                                     when {
//                                         e.message?.contains("StopIteration") == true -> {
//                                             Log.d("YTMusicAPI", "BatchSongsStreamHandler: Python iterator StopIteration received")
//                                             continuation.resume(null)
//                                         }
//                                         cancelled.get() -> {
//                                             Log.d("YTMusicAPI", "BatchSongsStreamHandler: Processing was cancelled")
//                                             continuation.resumeWithException(CancellationException("Processing cancelled"))
//                                         }
//                                         else -> {
//                                             Log.e("YTMusicAPI", "BatchSongsStreamHandler: Error in Python iterator", e)
//                                             continuation.resumeWithException(e)
//                                         }
//                                     }
//                                 }
//                             }
//                         } catch (e: Exception) {
//                             Log.e("YTMusicAPI", "BatchSongsStreamHandler: Error submitting to executor", e)
//                             continuation.resumeWithException(e)
//                         }
//                     }
//                 }
                
//                 if (item == null || item.isNone) {
//                     Log.d("YTMusicAPI", "BatchSongsStreamHandler: No more items (fetched: $itemsFetched, album_art: $albumArtCount, complete: $songCompleteCount)")
//                     break
//                 }
                
//                 itemsFetched++
//                 Log.d("YTMusicAPI", "BatchSongsStreamHandler: Successfully fetched item #$itemsFetched")
                
//                 // Reset retry count and consecutive error count on successful fetch
//                 retryCount = 0
//                 consecutiveErrors = 0
                
//                 val resultData = try {
//                     val converted = plugin.convertPythonDictToMap(item)
//                     Log.v("YTMusicAPI", "BatchSongsStreamHandler: Converted Python dict to map: ${converted.keys}")
//                     converted
//                 } catch (e: Exception) {
//                     Log.e("YTMusicAPI", "BatchSongsStreamHandler: Error converting Python result to map", e)
//                     consecutiveErrors++
//                     continue
//                 }
                
//                 val resultType = resultData["type"] as? String ?: "unknown"
//                 val resultIndex = resultData["index"] as? Int ?: -1
                
//                 Log.d("YTMusicAPI", "BatchSongsStreamHandler: Processing item type '$resultType' for index $resultIndex")
                
//                 withContext(Dispatchers.Main) {
//                     if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
//                         try {
//                             val eventData = when (resultType) {
//                                 "album_art" -> {
//                                     albumArtCount++  // ← Count album art events
//                                     Log.d("YTMusicAPI", "BatchSongsStreamHandler: Sending album_art event for index $resultIndex (count: $albumArtCount)")
//                                     mapOf(
//                                         "type" to "album_art",
//                                         "index" to resultIndex,
//                                         "albumArt" to resultData["album_art"],
//                                         "songName" to resultData["song_name"],
//                                         "artistName" to resultData["artist_name"],
//                                         "processed" to albumArtCount,
//                                         "total" to totalSongs
//                                     )
//                                 }
//                                 "song_complete" -> {
//                                     songCompleteCount++  // ← Count completed songs
//                                     Log.d("YTMusicAPI", "BatchSongsStreamHandler: Sending song_complete event for index $resultIndex (count: $songCompleteCount)")
//                                     mapOf(
//                                         "type" to "song_complete",
//                                         "title" to resultData["title"],
//                                         "artists" to resultData["artists"],
//                                         "videoId" to resultData["videoId"],
//                                         "albumArt" to resultData["albumArt"],
//                                         "audioUrl" to resultData["audioUrl"],
//                                         "processed" to songCompleteCount,
//                                         "total" to totalSongs
//                                     )
//                                 }
//                                 "album_art_error", "audio_url_error", "batch_error", "critical_error" -> {
//                                     Log.d("YTMusicAPI", "BatchSongsStreamHandler: Sending $resultType event for index $resultIndex: ${resultData["error"]}")
//                                     mapOf(
//                                         "type" to resultType,
//                                         "index" to resultIndex,
//                                         "error" to resultData["error"],
//                                         "songName" to resultData["song_name"],
//                                         "artistName" to resultData["artist_name"],
//                                         "stage" to resultData["stage"],
//                                         "processed" to songCompleteCount,
//                                         "total" to totalSongs
//                                     )
//                                 }
//                                 else -> {
//                                     Log.w("YTMusicAPI", "BatchSongsStreamHandler: Unknown result type: $resultType, sending as-is")
//                                     resultData + mapOf(
//                                         "processed" to songCompleteCount,
//                                         "total" to totalSongs
//                                     )
//                                 }
//                             }
                            
//                             events?.success(eventData)
//                             Log.v("YTMusicAPI", "BatchSongsStreamHandler: Successfully sent $resultType event to Flutter")
                            
//                         } catch (e: Exception) {
//                             Log.e("YTMusicAPI", "BatchSongsStreamHandler: Error sending event to Flutter", e)
//                             consecutiveErrors++
//                         }
//                     } else {
//                         Log.w("YTMusicAPI", "BatchSongsStreamHandler: Search is no longer latest, skipping event")
//                     }
//                 }
                
//                 // Periodic memory cleanup
//                 if (itemsFetched % 10 == 0) {
//                     cleanupMemory()
//                 }
                
//                 yield() // Cooperative cancellation point
                
//             } catch (e: Exception) {
//                 when {
//                     e.message?.contains("timeout") == true || e.message?.contains("timed out") == true -> {
//                         Log.w("YTMusicAPI", "BatchSongsStreamHandler: Item timeout (retry $retryCount/$MAX_RETRIES, fetched: $itemsFetched)")
//                         consecutiveErrors++
                        
//                         if (retryCount < MAX_RETRIES) {
//                             retryCount++
//                             delay(RETRY_DELAY_BASE * retryCount) // Exponential backoff
//                             continue
//                         } else {
//                             Log.e("YTMusicAPI", "BatchSongsStreamHandler: Max retries exceeded")
//                             break
//                         }
//                     }
//                     e is CancellationException -> {
//                         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Processing cancelled")
//                         break
//                     }
//                     else -> {
//                         Log.e("YTMusicAPI", "BatchSongsStreamHandler: Error processing item", e)
//                         consecutiveErrors++
                        
//                         // Send error event to Flutter
//                         withContext(Dispatchers.Main) {
//                             if (plugin.searchManager.isLatestOfType(searchId!!, SEARCH_TYPE)) {
//                                 try {
//                                     events?.success(mapOf(
//                                         "type" to "processing_error",
//                                         "error" to (e.message ?: "Unknown error"),
//                                         "processed" to songCompleteCount,
//                                         "total" to totalSongs
//                                     ))
//                                     Log.d("YTMusicAPI", "BatchSongsStreamHandler: Sent processing_error event")
//                                 } catch (sendError: Exception) {
//                                     Log.e("YTMusicAPI", "BatchSongsStreamHandler: Error sending error event", sendError)
//                                 }
//                             }
//                         }
                        
//                         if (itemsFetched == 0 && consecutiveErrors >= 3) {
//                             Log.e("YTMusicAPI", "BatchSongsStreamHandler: Too many consecutive errors at start, failing")
//                             throw e // Fail fast if we can't process anything
//                         }
                        
//                         delay(1000L) // Brief delay before continuing
//                         continue
//                     }
//                 }
//             }
//         }
        
//         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Finished processing - Items fetched: $itemsFetched, Album art: $albumArtCount, Songs complete: $songCompleteCount")
        
//         if (consecutiveErrors >= maxConsecutiveErrors) {
//             Log.e("YTMusicAPI", "BatchSongsStreamHandler: Stopped due to too many consecutive errors")
//         }
        
//         // Final memory cleanup
//         cleanupMemory()
//     }
    
//     private fun cleanup() {
//         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Starting cleanup")
        
//         searchId?.let { id ->
//             if (plugin.searchManager.has(id)) {
//                 plugin.searchManager.cancelSearch(id)
//                 Log.d("YTMusicAPI", "BatchSongsStreamHandler: Cancelled search $id")
//             }
//         }
        
//         processedResults.clear()
        
//         synchronized(executorLock) {
//             pythonExecutor?.let { executor ->
//                 if (!executor.isShutdown) {
//                     Log.d("YTMusicAPI", "BatchSongsStreamHandler: Shutting down executor")
//                     executor.shutdown()
//                     try {
//                         if (!executor.awaitTermination(5, TimeUnit.SECONDS)) {
//                             Log.w("YTMusicAPI", "Python executor did not terminate gracefully, forcing shutdown")
//                             executor.shutdownNow()
//                         } else {
//                             Log.d("YTMusicAPI", "BatchSongsStreamHandler: Executor terminated gracefully")
//                         }
//                     } catch (e: InterruptedException) {
//                         Log.w("YTMusicAPI", "Interrupted while waiting for executor termination")
//                         executor.shutdownNow()
//                         Thread.currentThread().interrupt()
//                     }
//                 }
//             }
//             pythonExecutor = null
//         }
        
//         Log.d("YTMusicAPI", "BatchSongsStreamHandler: Cleanup completed for searchId = $searchId")
//     }

//     override fun onCancel(arguments: Any?) {
//         Log.d("YTMusicAPI", "BatchSongsStreamHandler: onCancel called")
//         job?.cancel()
//         eventSink = null
//         cleanup()
//     }
// }