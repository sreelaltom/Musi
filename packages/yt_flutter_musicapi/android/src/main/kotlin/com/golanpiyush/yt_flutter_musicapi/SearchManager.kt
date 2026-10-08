package com.golanpiyush.yt_flutter_musicapi

import com.chaquo.python.PyObject
import kotlinx.coroutines.Job
import java.util.concurrent.ConcurrentHashMap
import android.util.Log

class SearchManager {

    private val activeSearches = ConcurrentHashMap<String, SearchHandle>()
    private val lock = Any()
    private val latestSearchIdsByType = mutableMapOf<String, String>()

    /** Register a search, cancel previous active searches of the same type */
   fun registerSearch(
        searchId: String,
        searchType: String,
        generator: PyObject,
        coroutineJob: Job
    ): String {
        synchronized(lock) {
            try {
                cancelType(searchType) // cancel old ones of the same type

                if (activeSearches.containsKey(searchId)) {
                    cancelSearch(searchId)
                    Log.w("YTMusicAPI", "Duplicate searchId detected during register: $searchId. Replacing it.")
                }

                val handle = SearchHandle(generator, coroutineJob, searchType)
                activeSearches[searchId] = handle
                latestSearchIdsByType[searchType] = searchId // Store as latest ID for this type
                
                Log.d("YTMusicAPI", "Registered search: $searchId [type: $searchType]")
                return searchId
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "Failed to register search: ${e.message}", e)
                throw RuntimeException("Search registration failed: ${e.message}")
            }
        }
    }

    // Add this new method
    fun isLatestOfType(searchId: String, type: String): Boolean {
        synchronized(lock) {
            return latestSearchIdsByType[type] == searchId
        }
    }
    
    fun has(searchId: String): Boolean {
        synchronized(lock) {
            return activeSearches.containsKey(searchId)
        }
    }


    /** Cancel a specific search by ID */
    fun cancelSearch(searchId: String): Boolean {
        synchronized(lock) {
            val handle = activeSearches.remove(searchId) ?: run {
                Log.w("YTMusicAPI", "Search $searchId not found for cancellation")
                return false
            }

            return try {
                handle.cancel()
                Log.d("YTMusicAPI", "Successfully cancelled search: $searchId")
                true
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "Failed to cancel search: $searchId - ${e.message}", e)
                false
            }
        }
    }

    /** Cancel all active searches of a specific type */
    fun cancelType(searchType: String): Int {
        synchronized(lock) {
            val idsOfType = activeSearches.filter { it.value.searchType == searchType }.keys
            var cancelledCount = 0

            for (searchId in idsOfType) {
                try {
                    if (cancelSearch(searchId)) {
                        cancelledCount++
                    }
                } catch (e: Exception) {
                    Log.w("YTMusicAPI", "Exception cancelling type $searchType search $searchId: ${e.message}")
                }
            }

            Log.i("YTMusicAPI", "Cancelled $cancelledCount searches of type $searchType")
            return cancelledCount
        }
    }

    /** Cancel all current searches */
    fun cancelAll(): Int {
        synchronized(lock) {
            val total = activeSearches.size
            activeSearches.values.forEach { handle ->
                try {
                    handle.cancel()
                } catch (e: Exception) {
                    Log.w("YTMusicAPI", "Error cancelling search handle: ${e.message}", e)
                }
            }
            activeSearches.clear()
            Log.i("YTMusicAPI", "Cancelled all ($total) active searches")
            return total
        }
    }

    /** Check if a specific search is still active */
    fun isActive(searchId: String): Boolean {
        synchronized(lock) {
            return try {
                val handle = activeSearches[searchId]
                if (handle != null) {
                    handle.updateLastAccessed()
                    true
                } else {
                    false
                }
            } catch (e: Exception) {
                Log.w("YTMusicAPI", "Error checking activity for $searchId: ${e.message}")
                false
            }
        }
    }

    /** Get count of active searches by type */
    fun getActiveCounts(): Map<String, Int> {
        synchronized(lock) {
            return try {
                val counts = mutableMapOf<String, Int>()
                activeSearches.values.forEach { handle ->
                    counts[handle.searchType] = counts.getOrDefault(handle.searchType, 0) + 1
                }
                counts
            } catch (e: Exception) {
                Log.e("YTMusicAPI", "Error retrieving active search counts: ${e.message}")
                emptyMap()
            }
        }
    }

    /** Remove stale searches (never accessed in [timeoutMillis]) */
    fun cleanupStale(timeoutMillis: Long = 5 * 60 * 1000): Int {
        synchronized(lock) {
            val now = System.currentTimeMillis()
            val staleIds = activeSearches.filter { now - it.value.lastAccessed > timeoutMillis }.keys
            var cleanedCount = 0

            for (searchId in staleIds) {
                try {
                    if (cancelSearch(searchId)) {
                        cleanedCount++
                    }
                } catch (e: Exception) {
                    Log.w("YTMusicAPI", "Error cleaning up stale search $searchId: ${e.message}")
                }
            }

            if (cleanedCount > 0) {
                Log.i("YTMusicAPI", "Cleaned $cleanedCount stale searches")
            }

            return cleanedCount
        }
    }
    
    fun dispose() {
        synchronized(lock) {
            Log.d("YTMusicAPI", "Disposing SearchManager...")
            
            // Cancel all active searches
            val cancelledCount = cancelAll()
            
            // Clear the latest search IDs tracking
            latestSearchIdsByType.clear()
            
            Log.d("YTMusicAPI", "SearchManager disposed. Cancelled $cancelledCount searches.")
        }
    }

    

    /** Represents one active search instance */
    inner class SearchHandle(
        private val generator: PyObject,
        private val job: Job,
        val searchType: String,
        var lastAccessed: Long = System.currentTimeMillis()
    ) {
        fun cancel() {
            
            tryClosingGenerator(searchType, generator)

            try {
                generator.callAttr("__close__")
                Log.d("YTMusicAPI", "Generator closed gracefully")
            } catch (e: Exception) {
                if (e.message?.contains("has no attribute '__close__'") == true) {
                    Log.d("YTMusicAPI", "Generator has no '__close__' method")
                } else {
                    Log.w("YTMusicAPI", "Error closing generator: ${e.message}", e)
                }
            }

        }

        private fun tryClosingGenerator(name: String, generator: PyObject?) {
            try {
                generator?.callAttr("__close__")
                Log.d("YTMusicAPI", "[$name] Generator closed successfully")
            } catch (e: Exception) {
                if (e.message?.contains("has no attribute '__close__'") == true) {
                    Log.d("YTMusicAPI", "[$name] Generator does not support __close__")
                } else {
                    Log.w("YTMusicAPI", "[$name] Failed to close generator: ${e.message}", e)
                }
            }
        }


        fun updateLastAccessed() {
            lastAccessed = System.currentTimeMillis()
        }
    }
}
