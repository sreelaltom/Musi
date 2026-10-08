from asyncio import as_completed
from concurrent.futures import ThreadPoolExecutor
from enum import Enum
import logging
import re
from types import GeneratorType
from typing import Any, Dict, Generator, List, Optional
import warnings
import random
import time
import socket
from urllib.error import URLError
import threading


# Suppress warnings
warnings.filterwarnings("ignore", category=DeprecationWarning)

ytmv = "1.11.5" '''Latest stable version as of July 2025'''
ytdlpv = "2026.08.19"

# For Debugging
try:
    from ytmusicapi import YTMusic
    import yt_dlp
    print("✅ Imported ytmusicapi and yt-dlp successfully")
except Exception as e:
    print("❌ Failed to import:", e)


class GeneratorState(Enum):
    CREATED = "created"
    RUNNING = "running"
    SUSPENDED = "suspended"
    CLOSED = "closed"
    ERROR = "error"



# Enums for quality settings
class AudioQuality(Enum):
    LOW = 0
    MED = 1
    HIGH = 2
    VERY_HIGH = 3

class ThumbnailQuality(Enum):
    LOW = 0
    MED = 1
    HIGH = 2
    VERY_HIGH = 3

class SafeGeneratorWrapper:
    """Wrapper that safely manages generator lifecycle and cancellation"""
    
    def __init__(self, generator: Generator, search_id: str, search_type: str):
        self.generator = generator
        self.search_id = search_id
        self.search_type = search_type
        self.state = GeneratorState.CREATED
        self.should_cancel = threading.Event()
        self.is_iterating = threading.Lock()
        self.created_time = time.time()
        self.last_access_time = time.time()
        self._exception = None
        
    def __iter__(self):
        return self
        
    def __next__(self):
        # Check if cancellation was requested before proceeding
        if self.should_cancel.is_set():
            self.state = GeneratorState.CLOSED
            raise StopIteration
            
        # Try to acquire iteration lock (non-blocking)
        if not self.is_iterating.acquire(blocking=False):
            # Generator is already being iterated - this shouldn't happen
            # but if it does, we'll wait briefly and try again
            time.sleep(0.01)
            if not self.is_iterating.acquire(blocking=False):
                raise RuntimeError(f"Generator {self.search_id} is already being iterated")
        
        try:
            self.state = GeneratorState.RUNNING
            self.last_access_time = time.time()
            
            # Check for cancellation again right before iteration
            if self.should_cancel.is_set():
                self.state = GeneratorState.CLOSED
                raise StopIteration
                
            result = next(self.generator)
            self.state = GeneratorState.SUSPENDED
            return result
            
        except StopIteration:
            self.state = GeneratorState.CLOSED
            raise
        except Exception as e:
            self.state = GeneratorState.ERROR
            self._exception = e
            raise
        finally:
            self.is_iterating.release()
    
    def cancel(self) -> bool:
        """Request cancellation of the generator"""
        if self.state in [GeneratorState.CLOSED, GeneratorState.ERROR]:
            return True
            
        self.should_cancel.set()
        
        # If we can acquire the iteration lock, the generator isn't running
        if self.is_iterating.acquire(blocking=False):
            try:
                if self.state != GeneratorState.CLOSED and hasattr(self.generator, 'close'):
                    try:
                        self.generator.close()
                    except (ValueError, RuntimeError, StopIteration):
                        # These are expected when closing a generator
                        pass
                    except Exception as e:
                        logging.warning(f"Unexpected error closing generator {self.search_id}: {e}")
                
                self.state = GeneratorState.CLOSED
                return True
            finally:
                self.is_iterating.release()
        else:
            # Generator is currently running, just set the cancel flag
            # The running iteration will see it and stop gracefully
            return True
    
    def is_active(self) -> bool:
        """Check if generator is still active (not closed/error)"""
        return self.state not in [GeneratorState.CLOSED, GeneratorState.ERROR] and not self.should_cancel.is_set()
    
    def get_info(self) -> Dict[str, Any]:
        """Get information about the generator state"""
        return {
            'search_id': self.search_id,
            'search_type': self.search_type,
            'state': self.state.value,
            'created_time': self.created_time,
            'last_access_time': self.last_access_time,
            'is_cancelled': self.should_cancel.is_set(),
            'exception': str(self._exception) if self._exception else None
        }


class SearchInspector:
    """Thread-safe singleton for managing active search generators"""
    
    _instance = None
    _lock = threading.Lock()
    
    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super(SearchInspector, cls).__new__(cls)
        return cls._instance
    
    def __init__(self):
        if not hasattr(self, 'initialized'):
            self.active_searches: Dict[str, SafeGeneratorWrapper] = {}
            self.lock = threading.RLock()  # Use RLock for nested locking
            self.logger = logging.getLogger(__name__)
            self.shutdown_event = threading.Event()
            self.cleanup_thread = None
            self.initialized = True
            self._start_cleanup_thread()
    
    @classmethod
    def get_instance(cls):
        """Get the singleton instance of SearchInspector"""
        return cls()
    
    def _start_cleanup_thread(self):
        """Start background thread for periodic cleanup"""
        def cleanup_worker():
            while not self.shutdown_event.wait(timeout=60):  # Check every minute
                try:
                    self.cleanup_stale(timeout=300)  # 5 minute timeout
                except Exception as e:
                    self.logger.error(f"Error in cleanup thread: {e}")
        
        self.cleanup_thread = threading.Thread(target=cleanup_worker, daemon=True)
        self.cleanup_thread.start()
        
    def register_search(self, search_id: Optional[str] = None, 
                      search_type: Optional[str] = None, 
                      generator: Optional[Generator] = None) -> str:
        """
        Register a new search and cancel any existing ones of the same type.
        
        Args:
            search_id: Optional custom ID for the search
            search_type: The type/category of search
            generator: The generator instance to manage
            
        Returns:
            The search ID (generated if not provided)
        """
        if not search_type:
            raise ValueError("search_type is required")
        if not isinstance(generator, GeneratorType):
            raise TypeError("generator must be a generator object")
            
        with self.lock:
            try:
                # Cancel any existing searches of this type
                cancelled_count = self.cancel_type(search_type)
                if cancelled_count > 0:
                    self.logger.debug(f"Cancelled {cancelled_count} existing {search_type} searches")
                
                # Generate a unique ID if not provided
                if not search_id:
                    search_id = f"{search_type}_{int(time.time() * 1000)}_{id(generator)}"
                    
                # Create safe wrapper
                wrapper = SafeGeneratorWrapper(generator, search_id, search_type)
                
                # Store the wrapper
                self.active_searches[search_id] = wrapper
                
                self.logger.debug(f"Registered new search: {search_id} of type {search_type}")
                return search_id
                
            except Exception as e:
                self.logger.error(f"Failed to register search: {str(e)}", exc_info=True)
                raise RuntimeError(f"Search registration failed: {str(e)}")
    
    def cancel_search(self, search_id: str) -> bool:
        """
        Cancel a specific search by ID.
        
        Args:
            search_id: The ID of the search to cancel
            
        Returns:
            bool: True if search was found and cancelled, False otherwise
        """
        if not search_id:
            raise ValueError("search_id is required")
            
        with self.lock:
            wrapper = self.active_searches.get(search_id)
            if not wrapper:
                self.logger.warning(f"Search {search_id} not found for cancellation")
                return False
                
            try:
                success = wrapper.cancel()
                
                # Remove from active searches
                if search_id in self.active_searches:
                    del self.active_searches[search_id]
                
                self.logger.debug(f"Cancelled search: {search_id}")
                return success
                
            except Exception as e:
                self.logger.error(f"Failed to cancel search {search_id}: {str(e)}", exc_info=True)
                return False
    
    def cancel_type(self, search_type: str) -> int:
        """
        Cancel all searches of a specific type.
        
        Args:
            search_type: The type of searches to cancel
            
        Returns:
            int: Number of searches cancelled
        """
        if not search_type:
            raise ValueError("search_type is required")
            
        with self.lock:
            cancelled = 0
            to_remove = []
            
            try:
                for search_id, wrapper in list(self.active_searches.items()):
                    if wrapper.search_type == search_type:
                        try:
                            if wrapper.cancel():
                                to_remove.append(search_id)
                                cancelled += 1
                        except Exception as e:
                            self.logger.warning(
                                f"Error canceling {search_type} search {search_id}: {str(e)}"
                            )
                            
                for search_id in to_remove:
                    self.active_searches.pop(search_id, None)
                        
                self.logger.debug(f"Cancelled {cancelled} searches of type {search_type}")
                return cancelled
                
            except Exception as e:
                self.logger.error(f"Failed to cancel searches of type {search_type}: {str(e)}")
                return 0
    
    def cancel_all(self) -> int:
        """
        Cancel all ongoing searches.
        
        Returns:
            int: Number of searches cancelled
        """
        with self.lock:
            count = len(self.active_searches)
            cancelled = 0
            
            try:
                for wrapper in list(self.active_searches.values()):
                    try:
                        if wrapper.cancel():
                            cancelled += 1
                    except Exception as e:
                        self.logger.warning(f"Error closing generator: {str(e)}")
                        
                self.active_searches.clear()
                self.logger.debug(f"Cancelled {cancelled}/{count} active searches")
                return cancelled
                
            except Exception as e:
                self.logger.error(f"Failed to cancel all searches: {str(e)}")
                return 0
    
    def is_active(self, search_id: str) -> bool:
        """
        Check if a search is still active.
        
        Args:
            search_id: The ID of the search to check
            
        Returns:
            bool: True if search is active, False otherwise
        """
        if not search_id:
            return False
            
        with self.lock:
            try:
                wrapper = self.active_searches.get(search_id)
                if wrapper:
                    return wrapper.is_active()
                return False
            except Exception as e:
                self.logger.warning(f"Error checking search activity for {search_id}: {str(e)}")
                return False
    
    def get_active_counts(self) -> Dict[str, int]:
        """
        Get counts of active searches by type.
        
        Returns:
            dict: Mapping of search types to active counts
        """
        with self.lock:
            try:
                counts = {}
                for wrapper in self.active_searches.values():
                    if wrapper.is_active():
                        counts[wrapper.search_type] = counts.get(wrapper.search_type, 0) + 1
                return counts
            except Exception as e:
                self.logger.error(f"Failed to get active counts: {str(e)}")
                return {}
    
    def get_search_info(self, search_id: str) -> Optional[Dict[str, Any]]:
        """
        Get detailed information about a specific search.
        
        Args:
            search_id: The ID of the search
            
        Returns:
            dict: Search information or None if not found
        """
        with self.lock:
            wrapper = self.active_searches.get(search_id)
            return wrapper.get_info() if wrapper else None
    
    def get_all_search_info(self) -> Dict[str, Dict[str, Any]]:
        """
        Get information about all active searches.
        
        Returns:
            dict: Mapping of search IDs to their information
        """
        with self.lock:
            return {
                search_id: wrapper.get_info() 
                for search_id, wrapper in self.active_searches.items()
            }
    
    def cleanup_stale(self, timeout: int = 300) -> int:
        """
        Clean up searches that have been inactive for too long.
        
        Args:
            timeout: Seconds of inactivity before considering stale (default 300)
            
        Returns:
            int: Number of stale searches cleaned up
        """
        if timeout <= 0:
            raise ValueError("timeout must be positive")
            
        with self.lock:
            cleaned = 0
            current_time = time.time()
            to_remove = []
            
            try:
                for search_id, wrapper in list(self.active_searches.items()):
                    if (current_time - wrapper.last_access_time > timeout or 
                        wrapper.state in [GeneratorState.CLOSED, GeneratorState.ERROR]):
                        try:
                            wrapper.cancel()
                            to_remove.append(search_id)
                            cleaned += 1
                        except Exception as e:
                            self.logger.warning(
                                f"Error cleaning up stale search {search_id}: {str(e)}"
                            )
                            
                for search_id in to_remove:
                    self.active_searches.pop(search_id, None)
                        
                if cleaned > 0:
                    self.logger.info(f"Cleaned up {cleaned} stale searches")
                return cleaned
                
            except Exception as e:
                self.logger.error(f"Failed to clean stale searches: {str(e)}")
                return 0
    
    def shutdown(self):
        """Gracefully shutdown the SearchInspector"""
        self.logger.info("Shutting down SearchInspector...")
        self.shutdown_event.set()
        
        # Cancel all searches
        self.cancel_all()
        
        # Wait for cleanup thread to finish
        if self.cleanup_thread and self.cleanup_thread.is_alive():
            self.cleanup_thread.join(timeout=5.0)
    
    def __del__(self):
        """Destructor to ensure all resources are cleaned up"""
        try:
            self.shutdown()
        except Exception as e:
            if hasattr(self, 'logger'):
                self.logger.warning(f"Error during cleanup: {str(e)}")



def get_instance(cls):
    if cls._instance is None:
        cls._instance = cls()
    return cls._instance

def check_ytmusic_and_ytdlp_ready():
    try:
        # Import and get version info
        import ytmusicapi
        import yt_dlp
        
        # Initialize YTMusic
        ytmusic = ytmusicapi.YTMusic()
        
        # Initialize yt-dlp
        ydl = yt_dlp.YoutubeDL()
        
        # Get version information
        ytmusic_version = ytmusicapi.__version__ if hasattr(ytmusicapi, '__version__') else 'Unknown'
        ytdlp_version = yt_dlp.version.__version__ if hasattr(yt_dlp, 'version') else 'Unknown'
        
        print("✅ YTMusic and yt-dlp initialized successfully")
        
        return {
            "success": True,
            "ytmusic_ready": True,
            "ytmusic_version": ytmusic_version,
            "ytdlp_ready": True,
            "ytdlp_version": ytdlp_version,
            "message": "✅ All systems ready and working.."
        }
    except Exception as e:
        print(f"❌ Initialization failed: {e}")
        return {
            "success": False,
            "message": f"Initialization failed: {str(e)}",
            "ytmusic_ready": False,
            "ytdlp_ready": False
        }

def debug_dependencies():
    import sys
    from importlib.util import find_spec
    
    dependencies = {
        'ytmusicapi': find_spec("ytmusicapi") is not None,
        'yt_dlp': find_spec("yt_dlp") is not None,
        'python_version': sys.version,
        'python_path': sys.path
    }
    return dependencies


class YTMusicSearcher:
    def __init__(self, proxy: Optional[str] = None, country: str = "US"):
        self.proxy = proxy
        self.country = country.upper() if country else "US"
        self.ytmusic = None

        # ADD THESE TWO LINES - Initialize cache for album art
        self._album_art_cache = {}  # Cache for album art URLs
        self._cache_max_size = 100  # Maximum cache size
        
        self._initialize_ytmusic()
        
    def _initialize_ytmusic(self):
        time.sleep(3)
        max_retries = 3
        for attempt in range(max_retries):
            try:
                self.ytmusic = YTMusic()
                return
            except Exception as e:
                if attempt == max_retries - 1:
                    raise ConnectionError(f"Failed to initialize YTMusic after {max_retries} attempts: {str(e)}")
                time.sleep(2 ** attempt)

    def _get_ytdlp_instance(self, format_selector: str):
        ydl_opts = {
            "quiet": True,
            "no_warnings": True,
            "skip_download": True,
            "nocheckcertificate": True,
            "format": format_selector,
            "extract_flat": False,
            "age_limit": 99,
            "socket_timeout": 30,
            "source_address": "0.0.0.0",
            "force_ipv4": True,
            "retries": 3,
            "fragment_retries": 10,
            "extractor_retries": 3,
            "buffersize": 1024 * 1024,
            "http_chunk_size": 1024 * 1024,
            "extractor_args": {
                "youtube": {
                    "player_client": ["android"],
                    "player_skip": ["configs"],
                    "skip": ["translated_subs", "hls"]
                }
            },
            "compat_opts": ["no-youtube-unavailable-videos"],
            "headers": self._generate_headers()
        }

        if self.proxy:
            ydl_opts["proxy"] = self.proxy
            ydl_opts["proxy_headers"] = ydl_opts["headers"]

        return yt_dlp.YoutubeDL(ydl_opts)

    def _generate_headers(self):
        user_agents = [
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15',
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        ]
        
        return {
            'User-Agent': random.choice(user_agents),
            'Accept-Language': 'en-US,en;q=0.9',
            'Accept': '*/*',
            'Accept-Encoding': 'gzip, deflate, br'
        }

    # def get_audio_url(self, video_id: str, quality: AudioQuality = None) -> Optional[str]:
    #     format_strategies = [
    #         "bestaudio[ext=m4a]/bestaudio[ext=mp4]/best[ext=m4a]/best[ext=mp4]",
    #         "320/256/251/250/249/140/139/171/18",
    #         "bestaudio/best",
    #         "worstaudio/worst"
    #     ]
        
    #     for format_selector in format_strategies:
    #         try:
    #             ydl = self._get_ytdlp_instance(format_selector)
    #             time.sleep(random.uniform(0.5, 1.5))
                
    #             info = ydl.extract_info(
    #                 f"https://www.youtube.com/watch?v={video_id}",
    #                 download=False,
    #                 process=False
    #             )
    #             info = ydl.process_ie_result(info, download=False)
                
    #             if info.get('is_live') or info.get('availability') == 'unavailable':
    #                 continue
                    
    #             if info.get('drm') or any(f.get('drm') for f in info.get('formats', [])):
    #                 continue
                    
    #             requested_formats = info.get('requested_formats', [info])
    #             formats = info.get('formats', requested_formats)
                
    #             audio_formats = [
    #                 f for f in formats
    #                 if f.get('acodec') != 'none'
    #                 and f.get('url')
    #                 and not any(x in f['url'].lower() for x in ["manifest", ".m3u8"])
    #             ]
                
    #             if not audio_formats:
    #                 continue
                    
    #             # Sort formats by audio bitrate (highest first)
    #             audio_formats.sort(key=lambda f: f.get('abr', 0) or f.get('tbr', 0) or 0, reverse=True)
                
    #             # Try to find formats in this priority: 320 > 256 > 128
    #             for target_bitrate in [320, 256, 128]:
    #                 for fmt in audio_formats:
    #                     current_bitrate = fmt.get('abr', 0) or fmt.get('tbr', 0) or 0
    #                     if current_bitrate >= target_bitrate * 0.9:  # Allow 10% tolerance
    #                         quality_found = None
    #                         if current_bitrate >= 290:  # ~320kbps
    #                             quality_found = "320kbps"
    #                         elif current_bitrate >= 230:  # ~256kbps
    #                             quality_found = "256kbps"
    #                         else:  # ~128kbps
    #                             quality_found = "128kbps"
                            
    #                         print(f"🎵 Found audio at {quality_found} (actual: {current_bitrate:.0f}kbps)")
    #                         return fmt['url']
                
    #             # If no high quality formats found, return the best available
    #             if audio_formats:
    #                 current_bitrate = audio_formats[0].get('abr', 0) or audio_formats[0].get('tbr', 0) or 0
    #                 print(f"⚠️ Using best available audio: {current_bitrate:.0f}kbps")
    #                 return audio_formats[0]['url']
                    
    #         except yt_dlp.DownloadError as e:
    #             if "HTTP Error 403" in str(e):
    #                 time.sleep(2)
    #                 continue
    #             if "unavailable" in str(e).lower():
    #                 break
    #             continue
    #         except (URLError, socket.timeout, ConnectionError):
    #             time.sleep(2)
    #             continue
    #         except Exception:
    #             continue
        
    #     print("❌ No suitable audio formats found")
    #     return None

    def get_audio_url_fast(self, video_id: str) -> Optional[str]:
        """
        Audio URL extraction with format processing and signature deciphering.
        Returns a JSON string containing the playable audio URL and required HTTP headers.
        """
        if not video_id:
            return None
        
        try:
            ydl_opts = {
                "quiet": True,
                "no_warnings": True,
                "skip_download": True,
                "nocheckcertificate": True,
                "format": "bestaudio[ext=m4a]/bestaudio/best",
                "extract_flat": False,
                "socket_timeout": 15,
                "retries": 1,
                "extractor_args": {
                    "youtube": {
                        "player_client": ["android"],
                        "player_skip": ["configs"],
                        "skip": ["translated_subs", "hls"]
                    }
                },
                "headers": {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                    'Accept-Language': 'en-US,en;q=0.9',
                }
            }
            
            if self.proxy:
                ydl_opts["proxy"] = self.proxy
            
            ydl = yt_dlp.YoutubeDL(ydl_opts)
            
            # Process with process=True so signatures and 'n' throttling challenge are deciphered
            info = ydl.extract_info(
                f"https://www.youtube.com/watch?v={video_id}",
                download=False,
                process=True
            )
            
            if not info or info.get('is_live') or info.get('availability') == 'unavailable':
                return None
            
            selected_url = info.get('url')
            default_headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
            }
            selected_headers = info.get('http_headers') or default_headers
            
            if not selected_url:
                formats = info.get('formats', [])
                audio_formats = [
                    f for f in formats
                    if (f.get('acodec') != 'none' and 
                        f.get('url') and 
                        'manifest' not in f['url'].lower() and
                        '.m3u8' not in f['url'].lower())
                ]
                if audio_formats:
                    audio_formats.sort(key=lambda f: f.get('abr', 0) or f.get('tbr', 0) or 0, reverse=True)
                    best_fmt = audio_formats[0]
                    selected_url = best_fmt['url']
                    if best_fmt.get('http_headers'):
                        selected_headers = best_fmt['http_headers']
            
            if selected_url:
                import json
                return json.dumps({
                    "url": selected_url,
                    "headers": selected_headers,
                    "format_id": info.get('format_id', ''),
                    "ext": info.get('ext', 'm4a'),
                    "abr": info.get('abr', 0)
                })
            
            return None
            
        except Exception as e:
            print(f"Fast audio extraction failed for {video_id}: {e}")
            return None

    def get_audio_url(self, video_id: str, quality: AudioQuality = None) -> Optional[str]:
        # Define quality-based target bitrates
        if quality is None:
            quality = AudioQuality.HIGH
            
        quality_bitrates = {
            AudioQuality.LOW: [128, 96, 64],
            AudioQuality.MED: [192, 160, 128],
            AudioQuality.HIGH: [256, 192, 160],
            AudioQuality.VERY_HIGH: [320, 256, 192]
        }
        
        target_bitrates = quality_bitrates.get(quality, [256, 192, 160])
        
        format_strategies = [
            "bestaudio[ext=m4a]/bestaudio[ext=mp4]/best[ext=m4a]/best[ext=mp4]",
            "320/256/251/250/249/140/139/171/18",
            "bestaudio/best",
            "worstaudio/worst"
        ]
        
        for format_selector in format_strategies:
            try:
                ydl = self._get_ytdlp_instance(format_selector)
                time.sleep(random.uniform(0.5, 1.5))
                
                info = ydl.extract_info(
                    f"https://www.youtube.com/watch?v={video_id}",
                    download=False,
                    process=False
                )
                info = ydl.process_ie_result(info, download=False)
                
                if info.get('is_live') or info.get('availability') == 'unavailable':
                    continue
                    
                if info.get('drm') or any(f.get('drm') for f in info.get('formats', [])):
                    continue
                    
                requested_formats = info.get('requested_formats', [info])
                formats = info.get('formats', requested_formats)
                
                audio_formats = [
                    f for f in formats
                    if f.get('acodec') != 'none'
                    and f.get('url')
                    and not any(x in f['url'].lower() for x in ["manifest", ".m3u8"])
                ]
                
                if not audio_formats:
                    continue
                    
                # Sort formats by audio bitrate (highest first)
                audio_formats.sort(key=lambda f: f.get('abr', 0) or f.get('tbr', 0) or 0, reverse=True)
                
                # Try to find formats matching the requested quality
                for target_bitrate in target_bitrates:
                    for fmt in audio_formats:
                        current_bitrate = fmt.get('abr', 0) or fmt.get('tbr', 0) or 0
                        if current_bitrate >= target_bitrate * 0.9:  # Allow 10% tolerance
                            quality_found = None
                            if current_bitrate >= 290:  # ~320kbps
                                quality_found = "320kbps"
                            elif current_bitrate >= 230:  # ~256kbps
                                quality_found = "256kbps"
                            elif current_bitrate >= 150:  # ~192kbps
                                quality_found = "192kbps"
                            else:  # ~128kbps or lower
                                quality_found = "128kbps"
                            
                            print(f"🎵 Found audio at {quality_found} (actual: {current_bitrate:.0f}kbps)")
                            return fmt['url']
                
                # If no matching quality formats found, return the best available
                if audio_formats:
                    current_bitrate = audio_formats[0].get('abr', 0) or audio_formats[0].get('tbr', 0) or 0
                    print(f"⚠️ Using best available audio: {current_bitrate:.0f}kbps")
                    return audio_formats[0]['url']
                    
            except yt_dlp.DownloadError as e:
                if "HTTP Error 403" in str(e):
                    time.sleep(2)
                    continue
                if "unavailable" in str(e).lower():
                    break
                continue
            except (URLError, socket.timeout, ConnectionError):
                time.sleep(2)
                continue
            except Exception:
                continue
        
        print("❌ No suitable audio formats found")
        return None

    def _get_ytmusic_stream(self, video_id: str) -> Optional[str]:
        """Try to get high quality stream directly from YouTube Music"""
        try:
            song_info = self.ytmusic.get_song(video_id)
            if song_info:
                # Check for streaming data in the song info
                streaming_data = song_info.get('streamingData', {})
                if streaming_data:
                    # Prefer adaptive formats for higher quality
                    formats = streaming_data.get('adaptiveFormats', [])
                    for fmt in formats:
                        if fmt.get('mimeType', '').startswith('audio/'):
                            return fmt.get('url')
        except Exception as e:
            print(f"⚠️ YouTube Music stream fetch failed: {str(e)}")
        return None

    def _get_quality_label(self, fmt: dict) -> str:
        """Determine quality label based on format properties"""
        bitrate = fmt.get('abr', 0) or fmt.get('tbr', 0) or 0
        codec = (fmt.get('acodec') or '').lower()
        
        if bitrate >= 256 or 'opus' in codec:
            return "HIGH"
        elif bitrate >= 128:
            return "MEDIUM"
        return "LOW"
        
    def get_hq_album_art_from_ytdlp(self, video_id: str) -> Optional[str]:
        """Get high quality album art using yt-dlp from video metadata"""
        try:
            if not video_id:
                return None
                
            ydl_opts = {
                "quiet": True,
                "no_warnings": True,
                "skip_download": True,
                "nocheckcertificate": True,
                "extract_flat": False,
                "socket_timeout": 30,
                "source_address": "0.0.0.0",
                "force_ipv4": True,
                "retries": 2,
                "headers": self._generate_headers()
            }
            
            if self.proxy:
                ydl_opts["proxy"] = self.proxy
                ydl_opts["proxy_headers"] = ydl_opts["headers"]
            
            ydl = yt_dlp.YoutubeDL(ydl_opts)
            
            info = ydl.extract_info(
                f"https://www.youtube.com/watch?v={video_id}",
                download=False
            )
            
            if not info:
                return None
            
            # First try to get album art from metadata
            album_art_url = self._get_album_art_from_metadata(info)
            
            # If no album art from metadata, fall back to high quality thumbnails
            if not album_art_url:
                thumbnails = info.get('thumbnails', [])
                if thumbnails:
                    # Filter for high quality thumbnails (prefer square ones for album art)
                    hq_thumbnails = [
                        t for t in thumbnails 
                        if t and t.get('width', 0) >= 720 and t.get('height', 0) >= 720
                    ]
                    
                    if hq_thumbnails:
                        # Sort by resolution and prefer square aspect ratios
                        hq_thumbnails.sort(
                            key=lambda t: (
                                abs(1.0 - (t.get('width', 1) / t.get('height', 1))),  # Prefer square
                                (t.get('width', 0) * t.get('height', 0))  # Then by resolution
                            ),
                            reverse=True
                        )
                        album_art_url = hq_thumbnails[0].get('url', '')
                    else:
                        # Fall back to highest resolution thumbnail
                        valid_thumbnails = [t for t in thumbnails if t and t.get('url')]
                        if valid_thumbnails:
                            valid_thumbnails.sort(
                                key=lambda t: (t.get('width', 0) * t.get('height', 0)),
                                reverse=True
                            )
                            album_art_url = valid_thumbnails[0].get('url', '')
            
            if album_art_url:
                print(f"HQ Album Art found: {album_art_url}")
                return album_art_url
            
            return None
            
        except Exception as e:
            print(f"Error getting HQ album art for {video_id}: {e}")
            return None

    def _get_album_art_from_metadata(self, info: dict) -> Optional[str]:
        """Try to get album art from video metadata"""
        try:
            if not info or not isinstance(info, dict):
                return None
                
            # Check for album art in various metadata fields
            album_art_fields = ['album_art', 'album_artwork', 'artwork', 'cover']
            
            for field in album_art_fields:
                if info.get(field):
                    return info[field]
            
            # Try to get from uploader avatar if it's an official channel
            uploader = info.get('uploader', '').lower()
            if any(keyword in uploader for keyword in ['official', 'records', 'music', 'vevo']):
                uploader_avatar = info.get('uploader_avatar_url')
                if uploader_avatar:
                    return uploader_avatar
            
            return None
            
        except Exception:
            return None

    def get_youtube_music_album_art(self, video_id: str) -> Optional[str]:
        """Get album art specifically from YouTube Music metadata"""
        try:
            if not video_id:
                return None
                
            # Use YTMusic to get song details which might have better album art
            song_info = self.ytmusic.get_song(video_id)
            
            if not song_info:
                return None
            
            # Extract album art from song info
            thumbnails = song_info.get('videoDetails', {}).get('thumbnail', {}).get('thumbnails', [])
            
            if thumbnails:
                # Filter out None values
                valid_thumbnails = [t for t in thumbnails if t and t.get('url')]
                
                if valid_thumbnails:
                    # Sort by resolution to get highest quality
                    valid_thumbnails.sort(
                        key=lambda t: (t.get('width', 0) * t.get('height', 0)),
                        reverse=True
                    )
                    
                    # Prefer square thumbnails for album art
                    square_thumbnails = [
                        t for t in valid_thumbnails 
                        if abs(1.0 - (t.get('width', 1) / t.get('height', 1))) < 0.1
                    ]
                    
                    if square_thumbnails:
                        return square_thumbnails[0].get('url', '')
                    else:
                        return valid_thumbnails[0].get('url', '')
            
            return None
            
        except Exception as e:
            print(f"Error getting YouTube Music album art for {video_id}: {e}")
            return None

    def _get_album_art_unified(self, video_id: str, song_data: dict, thumb_quality: ThumbnailQuality) -> str:
        """Unified method with caching"""
        try:
            # Check cache first
            cache_key = f"{video_id}_{thumb_quality.value}"
            if cache_key in self._album_art_cache:
                return self._album_art_cache[cache_key]
            
            # Get album art (existing logic)
            album_art = ""
            thumbnails = song_data.get("thumbnails", [])
            
            if thumbnails and isinstance(thumbnails, list):
                thumbnails = [t for t in thumbnails if t and isinstance(t, dict)]
                google_thumbs = [t for t in thumbnails if t.get('url') and 'googleusercontent.com' in t.get('url', '')]
                
                if google_thumbs:
                    google_thumbs.sort(key=lambda t: (t.get('width', 0) * t.get('height', 0)), reverse=True)
                    base_url = google_thumbs[0].get('url', '')
                    
                    if base_url:
                        if thumb_quality == ThumbnailQuality.VERY_HIGH:
                            album_art = re.sub(r'w\d+-h\d+', 'w544-h544', base_url)
                        elif thumb_quality == ThumbnailQuality.HIGH:
                            album_art = re.sub(r'w\d+-h\d+', 'w320-h320', base_url)
                        elif thumb_quality == ThumbnailQuality.MED:
                            album_art = re.sub(r'w\d+-h\d+', 'w120-h120', base_url)
                        else:
                            album_art = re.sub(r'w\d+-h\d+', 'w60-h60', base_url)
            
            # Cache the result
            if album_art and len(self._album_art_cache) < self._cache_max_size:
                self._album_art_cache[cache_key] = album_art
            
            return album_art
            
        except Exception as e:
            print(f"⚠️ Error in _get_album_art_unified: {e}")
            return ""
    
    def _get_audio_url_with_retries(self, video_id: str, audio_quality: AudioQuality) -> Optional[str]:
        """Unified method to get audio URL with retries and fallback qualities"""
        print(f"🎵 Getting audio URL for: {video_id} with requested quality: {audio_quality}")
        
        # Define fallback strategy - try requested quality first, then lower ones
        quality_fallbacks = []
        
        if audio_quality == AudioQuality.VERY_HIGH:
            quality_fallbacks = [AudioQuality.VERY_HIGH, AudioQuality.HIGH, AudioQuality.MED]
        elif audio_quality == AudioQuality.HIGH:
            quality_fallbacks = [AudioQuality.HIGH, AudioQuality.MED, AudioQuality.LOW]
        elif audio_quality == AudioQuality.MED:
            quality_fallbacks = [AudioQuality.MED, AudioQuality.LOW]
        else:
            quality_fallbacks = [AudioQuality.LOW]
        
        for quality_attempt in quality_fallbacks:
            print(f"   Trying quality: {quality_attempt}")
            
            for attempt in range(2):  # Reduced attempts per quality
                try:
                    print(f"   Attempt {attempt + 1}/2 with quality {quality_attempt}")
                    
                    audio_url = self.get_audio_url(video_id, quality_attempt)
                    if audio_url:
                        print(f"✅ Successfully got audio URL with quality {quality_attempt} on attempt {attempt + 1}")
                        return audio_url
                    else:
                        print(f"⚠️ No audio URL returned with quality {quality_attempt} on attempt {attempt + 1}")
                    
                except Exception as e:
                    print(f"❌ Exception with quality {quality_attempt}, attempt {attempt + 1}: {e}")
                    
                    # If it's a rate limit error, wait longer
                    if any(code in str(e) for code in ["403", "429", "rate", "limit"]):
                        print(f"   📛 Rate limit detected, waiting 15 seconds...")
                        time.sleep(15)
                    else:
                        time.sleep(3)  # Normal retry delay
                
                # Don't retry immediately if we got None (video might be unavailable)
                if attempt == 0:
                    time.sleep(2)
        
        print(f"❌ All quality levels and retries failed for {video_id}")
        return None

    def _build_song_data(self, video_id: str, title: str, artists: str, duration: str, 
                        song_data: dict, thumb_quality: ThumbnailQuality, audio_quality: AudioQuality,
                        include_audio_url: bool, include_album_art: bool, **extra_fields) -> dict:
        """Unified method to build song data dictionary"""
        result = {
            "title": title,
            "artists": artists,
            "videoId": video_id,
            "duration": duration,
            **extra_fields
        }
        
        # Get album art
        if include_album_art:
            album_art = self._get_album_art_unified(video_id, song_data, thumb_quality)
            result["albumArt"] = album_art
        
        # Get audio URL
        if include_audio_url:
            audio_url = self._get_audio_url_with_retries(video_id, audio_quality)
            if audio_url:
                result["audioUrl"] = audio_url
        
        return result

    def get_music_details(
        self,
        query: str,
        limit: int = 50,
        thumb_quality: str = "VERY_HIGH",
        audio_quality: str = "HIGH",
        include_audio_url: bool = True,
        include_album_art: bool = True
    ) -> Generator[dict, None, None]:
        import time
        from concurrent.futures import ThreadPoolExecutor, as_completed
        
        inspector = SearchInspector.get_instance()
        search_id = f"search_{hash(query)}_{int(time.time())}"

        def generate_logic():
            try:
                print(f"[{search_id}] ✨ Streaming search for: {query}")
                
                if not inspector.is_active(search_id):
                    return

                # Get search results once
                results = None
                for attempt in range(2):  # Reduced from 3 attempts
                    if not inspector.is_active(search_id):
                        return
                    try:
                        results = self.ytmusic.search(query, filter="songs", limit=limit * 2)
                        break
                    except Exception as e:
                        if attempt == 1:
                            return
                        time.sleep(1)  # Reduced sleep time
                        self._initialize_ytmusic()

                if not results:
                    return

                processed_count = 0
                
                # Process in batches for faster throughput
                batch_size = 5 if include_audio_url else 10
                batch = []
                
                for item in results:
                    if not inspector.is_active(search_id):
                        return
                    if processed_count >= limit:
                        break

                    video_id = item.get("videoId")
                    if not video_id:
                        continue

                    batch.append(item)
                    
                    # Process batch when full or at end
                    if len(batch) >= batch_size or item == results[-1]:
                        # Process batch in parallel
                        if include_audio_url:
                            yield from self._process_search_batch_parallel(
                                batch, search_id, thumb_quality, audio_quality,
                                include_album_art, inspector
                            )
                        else:
                            # Fast path without audio URLs
                            for batch_item in batch:
                                if not inspector.is_active(search_id):
                                    return
                                if processed_count >= limit:
                                    break
                                    
                                song_data = self._build_song_data_fast(
                                    batch_item, thumb_quality, 
                                    include_album_art=include_album_art
                                )
                                
                                if song_data:
                                    yield song_data
                                    processed_count += 1
                        
                        batch = []

            except GeneratorExit:
                print(f"[{search_id}] 🔚 Generator closed")
                raise
            except Exception as e:
                print(f"[{search_id}] 💥 Unexpected error: {e}")
                raise

        def safe_generator():
            yield from generate_logic()

        gen = safe_generator()
        inspector.register_search(search_id, "music_search", gen)

        try:
            yield from gen
        finally:
            inspector.cancel_search(search_id)

    def _process_search_batch_parallel(
        self, 
        batch: List[dict], 
        search_id: str,
        thumb_quality: ThumbnailQuality,
        audio_quality: AudioQuality,
        include_album_art: bool,
        inspector
    ) -> Generator[dict, None, None]:
        """Process a batch of songs in parallel for faster results"""
        from concurrent.futures import ThreadPoolExecutor
        
        def process_single_item(item):
            try:
                video_id = item.get("videoId")
                title = item.get("title", "Unknown")
                artists = ", ".join([a.get("name", "Unknown") for a in item.get("artists", [])]) or "Unknown Artist"
                
                # Get audio URL using fast method
                audio_url = self.get_audio_url_fast(video_id)
                
                if not audio_url:
                    return None
                
                song_data = {
                    "title": title,
                    "artists": artists,
                    "videoId": video_id,
                    "duration": item.get("duration"),
                    "year": item.get("year"),
                    "audioUrl": audio_url
                }
                
                if include_album_art:
                    song_data["albumArt"] = self._get_album_art_unified(
                        video_id, item, thumb_quality
                    )
                
                return song_data
            except Exception as e:
                print(f"Error processing item: {e}")
                return None
        
        # Process in parallel with max 3 workers for balance
        with ThreadPoolExecutor(max_workers=3) as executor:
            futures = {executor.submit(process_single_item, item): item for item in batch}
            
            for future in futures:
                if not inspector.is_active(search_id):
                    return
                
                try:
                    result = future.result(timeout=2)
                    if result:
                        yield result
                except Exception as e:
                    print(f"Batch processing error: {e}")
                    continue

    def _build_song_data_fast(
        self,
        item: dict,
        thumb_quality: ThumbnailQuality,
        include_album_art: bool = True
    ) -> Optional[dict]:
        """Fast song data building without audio URL"""
        try:
            video_id = item.get("videoId")
            if not video_id:
                return None
            
            title = item.get("title", "Unknown")
            artists = ", ".join([a.get("name", "Unknown") for a in item.get("artists", [])]) or "Unknown Artist"
            
            song_data = {
                "title": title,
                "artists": artists,
                "videoId": video_id,
                "duration": item.get("duration"),
                "year": item.get("year")
            }
            
            if include_album_art:
                # Quick album art extraction
                thumbnails = item.get("thumbnails", [])
                if thumbnails:
                    base_url = thumbnails[-1].get("url", "")
                    if base_url:
                        if thumb_quality == ThumbnailQuality.VERY_HIGH:
                            song_data["albumArt"] = re.sub(r'w\d+-h\d+', 'w544-h544', base_url)
                        elif thumb_quality == ThumbnailQuality.HIGH:
                            song_data["albumArt"] = re.sub(r'w\d+-h\d+', 'w320-h320', base_url)
                        else:
                            song_data["albumArt"] = base_url
            
            return song_data
        except Exception as e:
            print(f"Error building fast song data: {e}")
            return None

    def get_radio(
        self,
        video_id: str,
        limit: int = 100,
        thumb_quality: str = "VERY_HIGH",
        audio_quality: str = "HIGH",
        include_audio_url: bool = True,
        include_album_art: bool = True
    ) -> Generator[Dict[str, Any], None, None]:
        """Generate radio playlist from a given video ID."""
        import time
        inspector = SearchInspector.get_instance()
        search_id = f"radio_{hash(video_id)}_{int(time.time())}"

        # Convert string parameters to enum objects
        thumb_quality_enum = ThumbnailQuality[thumb_quality] if hasattr(ThumbnailQuality, thumb_quality) else ThumbnailQuality.VERY_HIGH
        audio_quality_enum = AudioQuality[audio_quality] if hasattr(AudioQuality, audio_quality) else AudioQuality.HIGH

        def generate_logic():
            print(f"[{search_id}] 📻 Generating radio playlist from video ID: {video_id}")

            try:
                # Get radio playlist
                radio_playlist = self.ytmusic.get_watch_playlist(
                    videoId=video_id,
                    radio=True,
                    limit=limit
                )

                if not radio_playlist or not radio_playlist.get("tracks"):
                    print(f"[{search_id}] ❌ No radio tracks found")
                    return

                tracks = radio_playlist["tracks"]
                
                # Filter out the original video ID from the playlist
                filtered_tracks = [track for track in tracks if track.get("videoId") != video_id]
                
                # Limit the tracks to the requested amount
                final_tracks = filtered_tracks[:limit]
                
                print(f"[{search_id}] 🎵 Found {len(final_tracks)} radio tracks")

                processed_count = 0

                for track in final_tracks:
                    if not inspector.is_active(search_id):
                        return
                    if processed_count >= limit:
                        break

                    track_video_id = track.get("videoId")
                    if not track_video_id:
                        continue

                    try:
                        # Extract artist name for consistency
                        artists_list = track.get('artists', [])
                        if artists_list:
                            # Use the first artist as the primary artist
                            primary_artist = artists_list[0].get('name', 'Unknown')
                            # Create artists string like in get_artist_songs
                            artists_string = ", ".join(a.get('name', 'Unknown') for a in artists_list)
                        else:
                            primary_artist = 'Unknown'
                            artists_string = 'Unknown'

                       # Properly handle the thumbnail structure from get_watch_playlist
                        if 'thumbnail' in track and isinstance(track['thumbnail'], list):
                            track['thumbnails'] = track['thumbnail']  # Radio already has proper Google URLs
                        elif 'thumbnails' not in track:
                            track['thumbnails'] = []

                        # Build track data using the same method as get_artist_songs
                        track_data = self._build_song_data(
                            video_id=track_video_id,
                            title=track.get('title', 'Unknown'),
                            artists=artists_string,
                            duration=track.get('duration'),
                            song_data=track,
                            thumb_quality=thumb_quality_enum,
                            audio_quality=audio_quality_enum,
                            include_album_art=include_album_art,
                            include_audio_url=include_audio_url,
                            year=track.get('year'),
                            artist_name=primary_artist
                        )

                        # Only yield if we have valid track data
                        if track_data and (not include_audio_url or track_data.get('audioUrl')):
                            processed_count += 1
                            print(f"[{search_id}] 🎧 Yielding radio track {processed_count}: {track_data.get('title', 'Unknown')} - {track_data.get('artists', 'Unknown')}")
                            yield track_data

                    except Exception as e:
                        print(f"[{search_id}] ⚠️ Error processing radio track: {e}")
                        continue

                print(f"[{search_id}] ✅ Radio generation complete. Yielded {processed_count} tracks")

            except GeneratorExit:
                print(f"[{search_id}] 🔚 Generator closed")
                raise
            except Exception as e:
                print(f"[{search_id}] 💥 Unexpected error: {e}")
                raise

        def generator():
            yield from generate_logic()

        gen = generator()
        inspector.register_search(search_id, "radio", gen)

        try:
            yield from gen
        finally:
            inspector.cancel_search(search_id)




    def get_artist_songs(
        self,
        artist_name: str,
        limit: int = 80,
        thumb_quality: str = "VERY_HIGH",
        audio_quality: str = "HIGH",
        include_audio_url: bool = True,
        include_album_art: bool = True
    ) -> Generator[Dict[str, Any], None, None]:
        import time
        inspector = SearchInspector.get_instance()
        search_id = f"artist_{hash(artist_name)}_{int(time.time())}"

        # Convert string parameters to enum objects
        thumb_quality_enum = ThumbnailQuality[thumb_quality] if hasattr(ThumbnailQuality, thumb_quality) else ThumbnailQuality.VERY_HIGH
        audio_quality_enum = AudioQuality[audio_quality] if hasattr(AudioQuality, audio_quality) else AudioQuality.HIGH

        def generate_logic():
            retry_count = 0
            processed_count = 0
            max_retries = 3

            print(f"[{search_id}] 🎤 Fetching artist songs — {artist_name}")

            try:
                while retry_count < max_retries and processed_count < limit:
                    if not inspector.is_active(search_id):
                        return

                    try:
                        artist_results = self.ytmusic.search(artist_name, filter="artists", limit=limit)
                        target = next((r for r in artist_results if r.get("artist", "").lower() == artist_name.lower()), artist_results[0])
                        browse_id = target.get("browseId")
                        artist_data = self.ytmusic.get_artist(browse_id)
                        song_items = artist_data.get("songs", {}).get("results", []) or []

                        if not song_items and "albums" in artist_data:
                            for album in artist_data["albums"].get("results", [])[:3]:
                                if not inspector.is_active(search_id):
                                    return
                                album_tracks = self.ytmusic.get_album(album["browseId"]).get("tracks", [])
                                song_items.extend(album_tracks)

                        print(f"[{search_id}] 📦 {len(song_items)} tracks found")

                        for song in song_items:
                            if not inspector.is_active(search_id):
                                return
                            if processed_count >= limit:
                                break

                            vid = song.get("videoId")
                            if not vid:
                                continue

                            title = song.get("title", "Unknown")
                            artists = ", ".join(a.get("name", "Unknown") for a in song.get("artists", [])) or artist_name
                            song_data = self._build_song_data(
                                video_id=vid,
                                title=title,
                                artists=artists,
                                duration=song.get("duration"),
                                song_data=song,
                                thumb_quality=thumb_quality_enum,  # Pass enum instead of string
                                audio_quality=audio_quality_enum,  # Pass enum instead of string
                                include_album_art=include_album_art,
                                include_audio_url=include_audio_url,
                                year=song.get("year"),
                                artist_name=artist_name
                            )

                            if not include_audio_url or song_data.get("audioUrl"):
                                if not inspector.is_active(search_id):
                                    return
                                processed_count += 1
                                print(f"[{search_id}] 🎵 Yielding {processed_count}: {title}")
                                yield song_data

                        break

                    except Exception as e:
                        retry_count += 1
                        if retry_count >= max_retries:
                            print(f"[{search_id}] ❌ Failed after {retry_count} retries: {e}")
                            return
                        print(f"[{search_id}] ⚠️ Retry due to: {e}")
                        time.sleep(2 ** retry_count)
                        self._initialize_ytmusic()

            except GeneratorExit:
                print(f"[{search_id}] 🔚 Generator closed")
                raise

        def generator():
            yield from generate_logic()

        gen = generator()
        inspector.register_search(search_id, "artist_songs", gen)

        try:
            yield from gen
        finally:
            inspector.cancel_search(search_id)


    def get_charts(
        self,
        country: str = "US",
        limit: int = 50,
        thumb_quality: str = "VERY_HIGH",
        audio_quality: str = "HIGH",
        include_audio_url: bool = True,
        include_album_art: bool = True
    ) -> Generator[Dict[str, Any], None, None]:
        """Generate charts data from a given country code."""
        import time
        inspector = SearchInspector.get_instance()
        search_id = f"charts_{hash(country)}_{int(time.time())}"

        # Convert string parameters to enum objects
        thumb_quality_enum = ThumbnailQuality[thumb_quality] if hasattr(ThumbnailQuality, thumb_quality) else ThumbnailQuality.VERY_HIGH
        audio_quality_enum = AudioQuality[audio_quality] if hasattr(AudioQuality, audio_quality) else AudioQuality.HIGH

        def generate_logic():
            print(f"[{search_id}] 📊 Fetching charts for country: {country}")

            try:
                # Get charts data
                charts_data = self.ytmusic.get_charts(country=country)

                if not charts_data:
                    print(f"[{search_id}] ❌ No charts data found for country: {country}")
                    return

                processed_count = 0
                
                # Process songs from charts
                songs_section = charts_data.get("songs", {})
                if songs_section and "items" in songs_section:
                    songs = songs_section["items"]
                    print(f"[{search_id}] 🎵 Found {len(songs)} chart songs")
                    
                    for song in songs:
                        if not inspector.is_active(search_id):
                            return
                        if processed_count >= limit:
                            break

                        song_video_id = song.get("videoId")
                        if not song_video_id:
                            continue

                        try:
                            # Extract artist information
                            artists_list = song.get('artists', [])
                            if artists_list:
                                # Use the first artist as the primary artist
                                primary_artist = artists_list[0].get('name', 'Unknown')
                                # Create artists string
                                artists_string = ", ".join(a.get('name', 'Unknown') for a in artists_list)
                            else:
                                primary_artist = 'Unknown'
                                artists_string = 'Unknown'

                            # Handle thumbnails
                            if 'thumbnails' not in song:
                                song['thumbnails'] = []

                            # Build track data
                            track_data = self._build_song_data(
                                video_id=song_video_id,
                                title=song.get('title', 'Unknown'),
                                artists=artists_string,
                                duration=None,  # Charts don't typically include duration
                                song_data=song,
                                thumb_quality=thumb_quality_enum,
                                audio_quality=audio_quality_enum,
                                include_album_art=include_album_art,
                                include_audio_url=include_audio_url,
                                year=None,
                                artist_name=primary_artist
                            )

                            # Add chart-specific data
                            if track_data:
                                track_data['rank'] = song.get('rank', 'Unknown')
                                track_data['trend'] = song.get('trend', 'neutral')
                                track_data['isExplicit'] = song.get('isExplicit', False)
                                track_data['album'] = song.get('album', {})
                                track_data['chart_type'] = 'songs'
                                track_data['country'] = country

                                # Only yield if we have valid track data
                                if not include_audio_url or track_data.get('audioUrl'):
                                    processed_count += 1
                                    print(f"[{search_id}] 🎧 Yielding chart song {processed_count}: {track_data.get('title', 'Unknown')} - Rank: {track_data.get('rank', 'Unknown')}")
                                    yield track_data

                        except Exception as e:
                            print(f"[{search_id}] ⚠️ Error processing chart song: {e}")
                            continue

                # Process videos from charts
                videos_section = charts_data.get("videos", {})
                if videos_section and "items" in videos_section:
                    videos = videos_section["items"]
                    print(f"[{search_id}] 🎬 Found {len(videos)} chart videos")
                    
                    for video in videos:
                        if not inspector.is_active(search_id):
                            return
                        if processed_count >= limit:
                            break

                        video_id = video.get("videoId")
                        if not video_id:
                            continue

                        try:
                            # Extract artist information for videos
                            artists_list = video.get('artists', [])
                            if artists_list:
                                primary_artist = artists_list[0].get('name', 'Unknown')
                                artists_string = ", ".join(a.get('name', 'Unknown') for a in artists_list)
                            else:
                                primary_artist = 'Unknown'
                                artists_string = 'Unknown'

                            # Handle thumbnails
                            if 'thumbnails' not in video:
                                video['thumbnails'] = []

                            # Build track data for video
                            track_data = self._build_song_data(
                                video_id=video_id,
                                title=video.get('title', 'Unknown'),
                                artists=artists_string,
                                duration=None,
                                song_data=video,
                                thumb_quality=thumb_quality_enum,
                                audio_quality=audio_quality_enum,
                                include_album_art=include_album_art,
                                include_audio_url=include_audio_url,
                                year=None,
                                artist_name=primary_artist
                            )

                            # Add video-specific data
                            if track_data:
                                track_data['views'] = video.get('views', '0')
                                track_data['playlistId'] = video.get('playlistId', '')
                                track_data['chart_type'] = 'videos'
                                track_data['country'] = country

                                # Only yield if we have valid track data
                                if not include_audio_url or track_data.get('audioUrl'):
                                    processed_count += 1
                                    print(f"[{search_id}] 🎧 Yielding chart video {processed_count}: {track_data.get('title', 'Unknown')} - Views: {track_data.get('views', '0')}")
                                    yield track_data

                        except Exception as e:
                            print(f"[{search_id}] ⚠️ Error processing chart video: {e}")
                            continue

                # Process trending videos
                trending_section = charts_data.get("trending", {})
                if trending_section and "items" in trending_section:
                    trending = trending_section["items"]
                    print(f"[{search_id}] 🔥 Found {len(trending)} trending videos")
                    
                    for trend_video in trending:
                        if not inspector.is_active(search_id):
                            return
                        if processed_count >= limit:
                            break

                        video_id = trend_video.get("videoId")
                        if not video_id:
                            continue

                        try:
                            # Extract artist information for trending
                            artists_list = trend_video.get('artists', [])
                            if artists_list:
                                primary_artist = artists_list[0].get('name', 'Unknown')
                                artists_string = ", ".join(a.get('name', 'Unknown') for a in artists_list)
                            else:
                                primary_artist = 'Unknown'
                                artists_string = 'Unknown'

                            # Handle thumbnails
                            if 'thumbnails' not in trend_video:
                                trend_video['thumbnails'] = []

                            # Build track data for trending video
                            track_data = self._build_song_data(
                                video_id=video_id,
                                title=trend_video.get('title', 'Unknown'),
                                artists=artists_string,
                                duration=None,
                                song_data=trend_video,
                                thumb_quality=thumb_quality_enum,
                                audio_quality=audio_quality_enum,
                                include_album_art=include_album_art,
                                include_audio_url=include_audio_url,
                                year=None,
                                artist_name=primary_artist
                            )

                            # Add trending-specific data
                            if track_data:
                                track_data['views'] = trend_video.get('views', '0')
                                track_data['playlistId'] = trend_video.get('playlistId', '')
                                track_data['chart_type'] = 'trending'
                                track_data['country'] = country

                                # Only yield if we have valid track data
                                if not include_audio_url or track_data.get('audioUrl'):
                                    processed_count += 1
                                    print(f"[{search_id}] 🎧 Yielding trending video {processed_count}: {track_data.get('title', 'Unknown')} - Views: {track_data.get('views', '0')}")
                                    yield track_data

                        except Exception as e:
                            print(f"[{search_id}] ⚠️ Error processing trending video: {e}")
                            continue

                print(f"[{search_id}] ✅ Charts generation complete. Yielded {processed_count} items")

            except GeneratorExit:
                print(f"[{search_id}] 🔚 Generator closed")
                raise
            except Exception as e:
                print(f"[{search_id}] 💥 Unexpected error: {e}")
                raise

        def generator():
            yield from generate_logic()

        gen = generator()
        inspector.register_search(search_id, "charts", gen)

        try:
            yield from gen
        finally:
            inspector.cancel_search(search_id)

    def get_artist_albums(
        self,
        artist_name: str,
        max_albums: int = 5,
        max_songs_per_album: int = 10,
        thumb_quality: str = "VERY_HIGH",
        audio_quality: str = "HIGH",
        include_audio_url: bool = True,
        include_album_art: bool = True,
        max_workers: int = 5
    ) -> Generator[Dict[str, Any], None, None]:
        """Get artist albums with songs in each album using workers for parallel processing."""
        inspector = SearchInspector.get_instance()
        search_id = f"artist_albums_{hash(artist_name)}_{int(time.time())}"

        # Convert string parameters to enum objects
        thumb_quality_enum = ThumbnailQuality[thumb_quality] if hasattr(ThumbnailQuality, thumb_quality) else ThumbnailQuality.VERY_HIGH
        audio_quality_enum = AudioQuality[audio_quality] if hasattr(AudioQuality, audio_quality) else AudioQuality.HIGH

        def get_album_details(album_data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
            """Worker function to get album details."""
            try:
                album_id = album_data.get('browseId')
                if not album_id:
                    return None
                    
                album_details = self.ytmusic.get_album(album_id)
                if not album_details or not album_details.get('tracks'):
                    return None
                    
                return {
                    'album_info': album_data,
                    'details': album_details,
                    'tracks': album_details['tracks'][:max_songs_per_album]  # Limit songs per album
                }
            except Exception as e:
                print(f"[{search_id}] ⚠️ Error getting album details: {e}")
                return None

        def process_track_batch(track_batch: List[tuple]) -> List[Dict[str, Any]]:
            """Worker function to process a batch of tracks."""
            processed_tracks = []
            
            for album_title, track, year in track_batch:
                if not inspector.is_active(search_id):
                    break
                    
                try:
                    vid = track.get('videoId')
                    if not vid:
                        continue

                    track_data = self._build_song_data(
                        video_id=vid,
                        title=track.get('title', 'Unknown'),
                        artists=", ".join(a.get('name', 'Unknown') for a in track.get('artists', [])),
                        duration=track.get('duration'),
                        song_data=track,
                        thumb_quality=thumb_quality_enum,
                        audio_quality=audio_quality_enum,
                        include_album_art=include_album_art,
                        include_audio_url=include_audio_url,
                        year=year,
                        artist_name=artist_name
                    )

                    if not include_audio_url or track_data.get('audioUrl'):
                        track_data['album_title'] = album_title
                        processed_tracks.append(track_data)
                        
                except Exception as e:
                    print(f"[{search_id}] ⚠️ Error processing track: {e}")
                    continue
                    
            return processed_tracks

        def get_safe_album_art(tracks, thumb_quality_enum):
            """Safely get album art from tracks list."""
            if not tracks:
                return ""
            
            for track in tracks:
                if track and track.get('videoId'):
                    try:
                        return self._get_album_art_unified(track.get('videoId'), track, thumb_quality_enum)
                    except Exception as e:
                        print(f"[{search_id}] ⚠️ Error getting album art: {e}")
                        continue
            
            return ""

        def generate_logic():
            print(f"[{search_id}] 🎤 Fetching artist albums — {artist_name}")

            try:
                # Search for the artist
                artist_results = self.ytmusic.search(artist_name, filter="artists", limit=1)
                if not artist_results:
                    print(f"[{search_id}] ❌ No artist found")
                    return

                target = next((r for r in artist_results if r.get("artist", "").lower() == artist_name.lower()), artist_results[0])
                browse_id = target.get("browseId")
                artist_data = self.ytmusic.get_artist(browse_id)

                if 'albums' not in artist_data or not artist_data['albums'].get('results'):
                    print(f"[{search_id}] ❌ No albums found")
                    return

                # Get artist albums (limited to max_albums)
                albums = self.ytmusic.get_artist_albums(
                    artist_data['albums']['browseId'],
                    artist_data['albums']['params'],
                    limit=max_albums
                )[:max_albums]

                if not albums:
                    print(f"[{search_id}] ❌ No albums retrieved")
                    return

                # Phase 1: Get album details in parallel using workers
                print(f"[{search_id}] 📀 Processing {len(albums)} albums with {max_workers} workers")
                
                album_details_list = []
                with ThreadPoolExecutor(max_workers=max_workers) as executor:
                    # Submit all album detail tasks
                    future_to_album = {executor.submit(get_album_details, album): album for album in albums}
                    
                    # Collect results as they complete (without asyncio)
                    for future in future_to_album:
                        if not inspector.is_active(search_id):
                            break
                        try:
                            album_details = future.result(timeout=30)  # 30 second timeout per album
                            if album_details:
                                album_details_list.append(album_details)
                        except Exception as e:
                            print(f"[{search_id}] ⚠️ Error getting album details: {e}")
                            continue

                if not album_details_list:
                    print(f"[{search_id}] ❌ No valid album details retrieved")
                    return

                # Phase 2: Send album info immediately
                albums_info = {}
                for album_details in album_details_list:
                    album_info = album_details['album_info']
                    tracks = album_details['tracks']
                    
                    album_data = {
                        'type': 'album',
                        'title': album_info.get('title', 'Unknown Album'),
                        'year': album_info.get('year', ''),
                        'albumArt': get_safe_album_art(tracks, thumb_quality_enum),
                        'artist': artist_name,
                        'tracks': []
                    }
                    
                    albums_info[album_info.get('title', 'Unknown Album')] = album_data
                    print(f"[{search_id}] 💿 Yielding album: {album_data['title']}")
                    yield album_data

                # Phase 3: Process tracks in batches (same position from each album)
                max_tracks = max(len(details['tracks']) for details in album_details_list) if album_details_list else 0
                
                for track_index in range(max_tracks):
                    if not inspector.is_active(search_id):
                        break
                        
                    # Collect one track from each album at the same index
                    track_batch = []
                    for album_details in album_details_list:
                        if track_index < len(album_details['tracks']):
                            track = album_details['tracks'][track_index]
                            album_title = album_details['album_info'].get('title', 'Unknown Album')
                            year = album_details['album_info'].get('year', '')
                            track_batch.append((album_title, track, year))

                    if not track_batch:
                        continue

                    # Process this batch of tracks in parallel
                    batch_size = len(track_batch)
                    tracks_per_worker = max(1, batch_size // max_workers)
                    
                    with ThreadPoolExecutor(max_workers=min(max_workers, batch_size)) as executor:
                        futures = []
                        for i in range(0, batch_size, tracks_per_worker):
                            batch = track_batch[i:i + tracks_per_worker]
                            futures.append(executor.submit(process_track_batch, batch))
                        
                        # Collect processed tracks (without asyncio)
                        for future in futures:
                            if not inspector.is_active(search_id):
                                break
                                
                            try:
                                processed_tracks = future.result(timeout=30)  # 30 second timeout
                                for track_data in processed_tracks:
                                    album_title = track_data.pop('album_title')
                                    if album_title in albums_info:
                                        albums_info[album_title]['tracks'].append(track_data)
                                        print(f"[{search_id}] 🎵 Added track to {album_title}: {track_data.get('title', 'Unknown')}")
                            except Exception as e:
                                print(f"[{search_id}] ⚠️ Error processing track batch: {e}")
                                continue

                    # Yield updated albums after each batch
                    for album_title, album_data in albums_info.items():
                        if album_data['tracks']:  # Only yield if there are tracks
                            print(f"[{search_id}] 🔄 Updating album: {album_title} ({len(album_data['tracks'])} tracks)")
                            yield album_data.copy()  # Yield a copy to avoid reference issues

            except GeneratorExit:
                print(f"[{search_id}] 🔚 Generator closed")
                raise
            except Exception as e:
                print(f"[{search_id}] 💥 Unexpected error: {e}")
                raise

        def generator():
            yield from generate_logic()

        gen = generator()
        inspector.register_search(search_id, "artist_albums", gen)

        try:
            yield from gen
        finally:
            inspector.cancel_search(search_id)


    def get_artist_singles_eps(
        self,
        artist_name: str,
        max_singles: int = 5,
        max_songs_per_single: int = 10,
        thumb_quality: str = "VERY_HIGH",
        audio_quality: str = "HIGH",
        include_audio_url: bool = True,
        include_album_art: bool = True,
        max_workers: int = 5
    ) -> Generator[Dict[str, Any], None, None]:
        """Get artist singles and EPs with songs in each using workers for parallel processing."""
        inspector = SearchInspector.get_instance()
        search_id = f"artist_singles_{hash(artist_name)}_{int(time.time())}"

        # Convert string parameters to enum objects
        thumb_quality_enum = ThumbnailQuality[thumb_quality] if hasattr(ThumbnailQuality, thumb_quality) else ThumbnailQuality.VERY_HIGH
        audio_quality_enum = AudioQuality[audio_quality] if hasattr(AudioQuality, audio_quality) else AudioQuality.HIGH

        def get_single_details(single_data: Dict[str, Any]) -> Optional[Dict[str, Any]]:
            """Worker function to get single/EP details."""
            try:
                single_id = single_data.get('browseId')
                if not single_id:
                    return None
                    
                single_details = self.ytmusic.get_album(single_id)
                if not single_details or not single_details.get('tracks'):
                    return None
                    
                return {
                    'single_info': single_data,
                    'details': single_details,
                    'tracks': single_details['tracks'][:max_songs_per_single]  # Limit songs per single
                }
            except Exception as e:
                print(f"[{search_id}] ⚠️ Error getting single/EP details: {e}")
                return None

        def process_track_batch(track_batch: List[tuple]) -> List[Dict[str, Any]]:
            """Worker function to process a batch of tracks."""
            processed_tracks = []
            
            for single_title, track, year in track_batch:
                if not inspector.is_active(search_id):
                    break
                    
                try:
                    vid = track.get('videoId')
                    if not vid:
                        continue

                    track_data = self._build_song_data(
                        video_id=vid,
                        title=track.get('title', 'Unknown'),
                        artists=", ".join(a.get('name', 'Unknown') for a in track.get('artists', [])),
                        duration=track.get('duration'),
                        song_data=track,
                        thumb_quality=thumb_quality_enum,
                        audio_quality=audio_quality_enum,
                        include_album_art=include_album_art,
                        include_audio_url=include_audio_url,
                        year=year,
                        artist_name=artist_name
                    )

                    if not include_audio_url or track_data.get('audioUrl'):
                        track_data['single_title'] = single_title
                        processed_tracks.append(track_data)
                        
                except Exception as e:
                    print(f"[{search_id}] ⚠️ Error processing track: {e}")
                    continue
                    
            return processed_tracks

        def get_safe_album_art(tracks, thumb_quality_enum):
            """Safely get album art from tracks list."""
            if not tracks:
                return ""
            
            for track in tracks:
                if track and track.get('videoId'):
                    try:
                        return self._get_album_art_unified(track.get('videoId'), track, thumb_quality_enum)
                    except Exception as e:
                        print(f"[{search_id}] ⚠️ Error getting album art: {e}")
                        continue
            
            return ""

        def generate_logic():
            print(f"[{search_id}] 🎤 Fetching artist singles/EPs — {artist_name}")

            try:
                # Search for the artist
                artist_results = self.ytmusic.search(artist_name, filter="artists", limit=1)
                if not artist_results:
                    print(f"[{search_id}] ❌ No artist found")
                    return

                target = next((r for r in artist_results if r.get("artist", "").lower() == artist_name.lower()), artist_results[0])
                browse_id = target.get("browseId")
                artist_data = self.ytmusic.get_artist(browse_id)

                if 'singles' not in artist_data or not artist_data['singles'].get('results'):
                    print(f"[{search_id}] ❌ No singles/EPs found")
                    return

                # Get artist singles/EPs (limited to max_singles)
                singles = self.ytmusic.get_artist_albums(
                    artist_data['singles']['browseId'],
                    artist_data['singles']['params'],
                    limit=max_singles
                )[:max_singles]

                if not singles:
                    print(f"[{search_id}] ❌ No singles/EPs retrieved")
                    return

                # Phase 1: Get single/EP details in parallel using workers
                print(f"[{search_id}] 🎵 Processing {len(singles)} singles/EPs with {max_workers} workers")
                
                single_details_list = []
                with ThreadPoolExecutor(max_workers=max_workers) as executor:
                    # Submit all single detail tasks
                    future_to_single = {executor.submit(get_single_details, single): single for single in singles}
                    
                    # Collect results as they complete (without asyncio)
                    for future in future_to_single:
                        if not inspector.is_active(search_id):
                            break
                        try:
                            single_details = future.result(timeout=30)  # 30 second timeout per single
                            if single_details:
                                single_details_list.append(single_details)
                        except Exception as e:
                            print(f"[{search_id}] ⚠️ Error getting single details: {e}")
                            continue

                if not single_details_list:
                    print(f"[{search_id}] ❌ No valid single/EP details retrieved")
                    return

                # Phase 2: Send single/EP info immediately
                singles_info = {}
                for single_details in single_details_list:
                    single_info = single_details['single_info']
                    tracks = single_details['tracks']
                    
                    single_data = {
                        'type': 'single',
                        'title': single_info.get('title', 'Unknown Single/EP'),
                        'year': single_info.get('year', ''),
                        'albumArt': get_safe_album_art(tracks, thumb_quality_enum),
                        'artist': artist_name,
                        'tracks': []
                    }
                    
                    singles_info[single_info.get('title', 'Unknown Single/EP')] = single_data
                    print(f"[{search_id}] 🎵 Yielding single/EP: {single_data['title']}")
                    yield single_data

                # Phase 3: Process tracks in batches (same position from each single/EP)
                max_tracks = max(len(details['tracks']) for details in single_details_list) if single_details_list else 0
                
                for track_index in range(max_tracks):
                    if not inspector.is_active(search_id):
                        break
                        
                    # Collect one track from each single/EP at the same index
                    track_batch = []
                    for single_details in single_details_list:
                        if track_index < len(single_details['tracks']):
                            track = single_details['tracks'][track_index]
                            single_title = single_details['single_info'].get('title', 'Unknown Single/EP')
                            year = single_details['single_info'].get('year', '')
                            track_batch.append((single_title, track, year))

                    if not track_batch:
                        continue

                    # Process this batch of tracks in parallel
                    batch_size = len(track_batch)
                    tracks_per_worker = max(1, batch_size // max_workers)
                    
                    with ThreadPoolExecutor(max_workers=min(max_workers, batch_size)) as executor:
                        futures = []
                        for i in range(0, batch_size, tracks_per_worker):
                            batch = track_batch[i:i + tracks_per_worker]
                            futures.append(executor.submit(process_track_batch, batch))
                        
                        # Collect processed tracks (without asyncio)
                        for future in futures:
                            if not inspector.is_active(search_id):
                                break
                                
                            try:
                                processed_tracks = future.result(timeout=30)  # 30 second timeout
                                for track_data in processed_tracks:
                                    single_title = track_data.pop('single_title')
                                    if single_title in singles_info:
                                        singles_info[single_title]['tracks'].append(track_data)
                                        print(f"[{search_id}] 🎵 Added track to {single_title}: {track_data.get('title', 'Unknown')}")
                            except Exception as e:
                                print(f"[{search_id}] ⚠️ Error processing track batch: {e}")
                                continue

                    # Yield updated singles after each batch
                    for single_title, single_data in singles_info.items():
                        if single_data['tracks']:  # Only yield if there are tracks
                            print(f"[{search_id}] 🔄 Updating single: {single_title} ({len(single_data['tracks'])} tracks)")
                            yield single_data.copy()  # Yield a copy to avoid reference issues

            except GeneratorExit:
                print(f"[{search_id}] 🔚 Generator closed")
                raise
            except Exception as e:
                print(f"[{search_id}] 💥 Unexpected error: {e}")
                raise

        def generator():
            yield from generate_logic()

        gen = generator()
        inspector.register_search(search_id, "artist_singles", gen)

        try:
            yield from gen
        finally:
            inspector.cancel_search(search_id)

    def get_audio_url_flexible(
        self,
        title: Optional[str] = None,
        artist: Optional[str] = None,
        video_id: Optional[str] = None,
        audio_quality: str = "HIGH"
    ) -> Optional[str]:
        """
        Get audio URL for a song using flexible input parameters.
        
        Args:
            title: Song title (optional if video_id provided)
            artist: Artist name (optional if video_id provided)
            video_id: YouTube video ID (optional if title/artist provided)
            audio_quality: Audio quality ("LOW", "MED", "HIGH", "VERY_HIGH")
            
        Returns:
            str: Audio URL if found, None otherwise
            
        Raises:
            ValueError: If no valid identification parameters are provided
        """
        import time
        
        # Validate input parameters
        if not video_id and not (title or artist):
            raise ValueError("Either video_id OR (title and/or artist) must be provided")
        
        # Validate and normalize audio quality
        valid_qualities = ["LOW", "MED", "HIGH", "VERY_HIGH"]
        audio_quality = audio_quality.upper()
        
        # Handle common variations
        if audio_quality == "MEDIUM":
            audio_quality = "MED"
        elif audio_quality not in valid_qualities:
            print(f"⚠️ Invalid audio quality '{audio_quality}', using HIGH as default")
            audio_quality = "HIGH"
        
        target_video_id = video_id
        
        # If video_id not provided, search for it using title/artist
        if not target_video_id:
            print(f"🔍 Searching for video ID using title: '{title}', artist: '{artist}'")
            
            # Build search query
            search_terms = []
            if title:
                search_terms.append(title.strip())
            if artist:
                search_terms.append(artist.strip())
            
            search_query = " ".join(search_terms)
            
            if not search_query:
                raise ValueError("No valid search terms provided")
            
            # Search for the song
            max_search_attempts = 3
            for attempt in range(max_search_attempts):
                try:
                    search_results = self.ytmusic.search(search_query, filter="songs", limit=10)
                    
                    if not search_results:
                        print(f"❌ No search results found for: {search_query}")
                        return None
                    
                    # Find best match
                    best_match = None
                    best_score = 0
                    
                    for result in search_results:
                        result_title = result.get("title", "").lower().strip()
                        result_artists = [a.get("name", "").lower().strip() for a in result.get("artists", [])]
                        
                        # Calculate match score
                        title_score = 0
                        artist_score = 0
                        
                        if title:
                            title_lower = title.lower().strip()
                            if title_lower == result_title:
                                title_score = 100  # Perfect match
                            elif title_lower in result_title or result_title in title_lower:
                                title_score = 80   # Partial match
                        else:
                            title_score = 50  # No title to match against
                        
                        if artist:
                            artist_lower = artist.lower().strip()
                            if any(artist_lower == ra for ra in result_artists):
                                artist_score = 100  # Perfect match
                            elif any(artist_lower in ra or ra in artist_lower for ra in result_artists):
                                artist_score = 80   # Partial match
                        else:
                            artist_score = 50  # No artist to match against
                        
                        # Combined score (weighted toward title)
                        total_score = (title_score * 0.6) + (artist_score * 0.4)
                        
                        if total_score > best_score:
                            best_score = total_score
                            best_match = result
                    
                    if best_match:
                        target_video_id = best_match.get("videoId")
                        matched_title = best_match.get("title", "Unknown")
                        matched_artists = ", ".join(a.get("name", "Unknown") for a in best_match.get("artists", []))
                        
                        print(f"✅ Found match (score: {best_score:.1f}): '{matched_title}' by {matched_artists}")
                        print(f"🆔 Video ID: {target_video_id}")
                        break
                    else:
                        print(f"⚠️ No good matches found, using first result")
                        target_video_id = search_results[0].get("videoId")
                        break
                        
                except Exception as e:
                    print(f"⚠️ Search attempt {attempt + 1} failed: {e}")
                    if attempt == max_search_attempts - 1:
                        print(f"❌ All search attempts failed")
                        return None
                    time.sleep(2 ** attempt)
                    self._initialize_ytmusic()
        
        # Get audio URL using the video ID
        if not target_video_id:
            print(f"❌ No video ID available for audio extraction")
            return None
        
        print(f"🎵 Extracting {audio_quality} quality audio for video ID: {target_video_id}")
        
        try:
            # Use the existing get_audio_url method directly instead of _get_audio_url_with_retries
            audio_url = self.get_audio_url(target_video_id, quality=None)
            
            if audio_url:
                print(f"✅ Successfully extracted audio URL")
                return audio_url
            else:
                print(f"❌ Failed to extract audio URL")
                return None
                
        except Exception as e:
            print(f"❌ Error extracting audio URL: {e}")
            return None



    def fetch_ytmusic_lyrics(self, title: str, artist: str) -> Dict[str, Any]:
        """
        Fetch plain lyrics using YTMusicAPI.
        Returns consistent structure for Kotlin compatibility.
        When no lyrics found, returns error message as lyrics data.
        """
        try:
            # Search for songs - artist first, then song title
            search_query = f"{artist} {title}"
            print(f"Searching for: {search_query}")
            
            search_results = self.ytmusic.search(search_query, filter="songs", limit=10)
            
            if not search_results:
                error_msg = f"No search results found for '{title}' by '{artist}'"
                return {
                    'success': False,
                    'error': error_msg,
                    'lyrics': error_msg,  # Return error as lyrics data
                    'total_lines': 0,
                    'source': 'YTMusic'
                }
            
            print(f"Found {len(search_results)} search results")
            
            # Try each result until we find lyrics
            for i, result in enumerate(search_results):
                try:
                    if not isinstance(result, dict):
                        print(f"Skipping non-dict result {i}")
                        continue
                    
                    video_id = result.get('videoId')
                    if not video_id:
                        print(f"No videoId in result {i}")
                        continue
                    
                    result_title = result.get('title', '')
                    result_artists = [artist.get('name', '') for artist in result.get('artists', [])]
                    
                    print(f"Trying result {i}: '{result_title}' by {result_artists}")
                    
                    # Get song details
                    song_data = self.ytmusic.get_song(video_id)
                    if not song_data or not isinstance(song_data, dict):
                        print(f"No song data for {video_id}")
                        continue
                    
                    # Check if lyrics are available
                    lyrics_browse_id = song_data.get('lyrics')
                    if not lyrics_browse_id:
                        print(f"No lyrics available for '{result_title}'")
                        continue
                    
                    print(f"Found lyrics browse ID: {lyrics_browse_id}")
                    
                    # Get the actual lyrics
                    lyrics_data = self.ytmusic.get_lyrics(lyrics_browse_id)
                    if not lyrics_data or not isinstance(lyrics_data, dict):
                        print(f"Failed to get lyrics data for {lyrics_browse_id}")
                        continue
                    
                    raw_lyrics = lyrics_data.get('lyrics', '')
                    if not raw_lyrics or not isinstance(raw_lyrics, str):
                        print(f"No lyrics text found")
                        continue
                    
                    # Process lyrics into lines
                    lyrics_lines = []
                    for line_num, line in enumerate(raw_lyrics.strip().split('\n')):
                        line = line.strip()
                        if line:  # Skip empty lines
                            lyrics_lines.append({
                                'text': line,
                                'timestamp': -1,  # No timestamp available
                                'line_number': line_num
                            })
                    
                    if lyrics_lines:
                        print(f"Successfully found {len(lyrics_lines)} lyrics lines")
                        return {
                            'success': True,
                            'lyrics': lyrics_lines,
                            'source': 'YTMusic',
                            'total_lines': len(lyrics_lines),
                            'video_id': video_id,
                            'song_info': {
                                'title': result_title,
                                'artists': result_artists,
                                'duration': result.get('duration', ''),
                                'thumbnails': result.get('thumbnails', [])
                            }
                        }
                    else:
                        print(f"No valid lyrics lines found")
                        
                except Exception as e:
                    print(f"Error processing result {i}: {e}")
                    continue
            
            # No lyrics found in any result - return error as lyrics data
            error_msg = f"No lyrics found for '{title}' by '{artist}' searched in {len(search_results)} results"
            return {
                'success': False,
                'error': error_msg,
                'lyrics': error_msg,  # Return error message as lyrics data
                'total_lines': 0,
                'source': 'YTMusic'
            }
            
        except Exception as e:
            print(f"YTMusic lyrics fetch error: {e}")
            error_msg = f"YTMusic API error: {str(e)}"
            return {
                'success': False,
                'error': error_msg,
                'lyrics': error_msg,  # Return error message as lyrics data
                'total_lines': 0,
                'source': 'YTMusic'
            }
    
    def SearchStreamsCleanup(self):
        """Clean up resources"""
        try:
            if hasattr(self, 'yt_music'):
                del self.yt_music
            if hasattr(self, 'yt_dlp'):
                del self.yt_dlp
            # Clear any cached data
            if hasattr(self, '_cache'):
                self._cache.clear()
        except Exception as e:
            print(f"YTMusicSearcher cleanup error: {e}")

            
# =================================================================================================================================
# =================================================================================================================================


class YTMusicRelatedFetcher:
    def __init__(self, proxy: Optional[str] = None, country: str = "US"):
        self.proxy = proxy
        self.country = country.upper() if country else "US"
        self.ytmusic = None
        self._album_art_cache = {}  # cache INIT
        self._cache_max_size = 100 # cache limit
        self._initialize_ytmusic()
        
        
    def _initialize_ytmusic(self):
        max_retries = 3
        for attempt in range(max_retries):
            try:
                self.ytmusic = YTMusic()
                return
            except Exception as e:
                if attempt == max_retries - 1:
                    raise ConnectionError(f"PythonEngineExceptionsCritical: Failed to initialize YTMusic after {max_retries} attempts: {str(e)}")
                time.sleep(2 ** attempt)

    def _get_ytdlp_instance(self, format_selector: str):
        ydl_opts = {
            "quiet": True,
            "no_warnings": True,
            "skip_download": True,
            "nocheckcertificate": True,
            "format": format_selector,
            "extract_flat": False,
            "age_limit": 99,
            "socket_timeout": 30,
            "source_address": "0.0.0.0",
            "force_ipv4": True,
            "retries": 3,
            "fragment_retries": 10,
            "extractor_retries": 3,
            "buffersize": 1024 * 1024,
            "http_chunk_size": 1024 * 1024,
            "extractor_args": {
                "youtube": {
                    "player_client": ["android"],
                    "player_skip": ["configs"],
                    "skip": ["translated_subs", "hls"]
                }
            },
            "compat_opts": ["no-youtube-unavailable-videos"],
            "headers": self._generate_headers()
        }

        if self.proxy:
            ydl_opts["proxy"] = self.proxy
            ydl_opts["proxy_headers"] = ydl_opts["headers"]

        return yt_dlp.YoutubeDL(ydl_opts)

    def _generate_headers(self):
        user_agents = [
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15',
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        ]
        
        return {
            'User-Agent': random.choice(user_agents),
            'Accept-Language': 'en-US,en;q=0.9',
            'Accept': '*/*',
            'Accept-Encoding': 'gzip, deflate, br'
        }

    def get_audio_url(self, video_id: str, quality: AudioQuality = None) -> Optional[str]:
        format_strategies = [
            "bestaudio[ext=m4a]/bestaudio[ext=mp4]/best[ext=m4a]/best[ext=mp4]",
            "251/250/249/140/139/171/18/22",
            "bestaudio/best",
            "worstaudio/worst"
        ]

        for format_selector in format_strategies:
            try:
                ydl = self._get_ytdlp_instance(format_selector)
                time.sleep(random.uniform(0.5, 1.5))

                info = ydl.extract_info(
                    f"https://www.youtube.com/watch?v={video_id}",
                    download=False,
                    process=False
                )
                info = ydl.process_ie_result(info, download=False)

                if info.get('is_live') or info.get('availability') == 'unavailable':
                    continue

                if info.get('drm') or any(f.get('drm') for f in info.get('formats', [])):
                    continue

                requested_formats = info.get('requested_formats', [info])
                formats = info.get('formats', requested_formats)

                audio_formats = [
                    f for f in formats
                    if f.get('acodec') != 'none'
                    and f.get('url')
                    and not any(x in f['url'].lower() for x in ["manifest", ".m3u8"])
                ]

                if not audio_formats:
                    continue

                # Sort formats by audio bitrate (highest first)
                audio_formats.sort(key=lambda f: f.get('abr', 0) or f.get('tbr', 0) or 0, reverse=True)

                # Try to find formats in this priority: 320 > 256 > 128
                for target_bitrate in [320, 256, 128]:
                    for fmt in audio_formats:
                        current_bitrate = fmt.get('abr', 0) or fmt.get('tbr', 0) or 0
                        if current_bitrate >= target_bitrate * 0.9:  # Allow 10% tolerance
                            quality_found = None
                            if current_bitrate >= 290:  # ~320kbps
                                quality_found = "320kbps"
                            elif current_bitrate >= 230:  # ~256kbps
                                quality_found = "256kbps"
                            else:  # ~128kbps
                                quality_found = "128kbps"
                            
                            print(f"🎵 Found audio at {quality_found} (actual: {current_bitrate:.0f}kbps)")
                            return fmt['url']

                # If no high quality formats found, return the best available
                if audio_formats:
                    current_bitrate = audio_formats[0].get('abr', 0) or audio_formats[0].get('tbr', 0) or 0
                    print(f"⚠️ Using best available audio: {current_bitrate:.0f}kbps")
                    return audio_formats[0]['url']

            except yt_dlp.DownloadError as e:
                if "HTTP Error 403" in str(e):
                    time.sleep(2)
                    continue
                if "unavailable" in str(e).lower():
                    break
                continue
            except (URLError, socket.timeout, ConnectionError):
                time.sleep(2)
                continue
            except Exception:
                continue

        print("❌ No suitable audio formats found")
        return None
    
    def get_audio_url_fast(self, video_id: str) -> Optional[str]:
        """
        Audio URL extraction with format processing and signature deciphering.
        Returns a JSON string containing the playable audio URL and required HTTP headers.
        """
        if not video_id:
            return None
        
        try:
            ydl_opts = {
                "quiet": True,
                "no_warnings": True,
                "skip_download": True,
                "nocheckcertificate": True,
                "format": "bestaudio[ext=m4a]/bestaudio/best",
                "extract_flat": False,
                "socket_timeout": 15,
                "retries": 1,
                "extractor_args": {
                    "youtube": {
                        "player_client": ["android"],
                        "player_skip": ["configs"],
                        "skip": ["translated_subs", "hls"]
                    }
                },
                "headers": {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                    'Accept-Language': 'en-US,en;q=0.9',
                }
            }
            
            if self.proxy:
                ydl_opts["proxy"] = self.proxy
            
            ydl = yt_dlp.YoutubeDL(ydl_opts)
            
            # Process with process=True so signatures and 'n' throttling challenge are deciphered
            info = ydl.extract_info(
                f"https://www.youtube.com/watch?v={video_id}",
                download=False,
                process=True
            )
            
            if not info or info.get('is_live') or info.get('availability') == 'unavailable':
                return None
            
            selected_url = info.get('url')
            default_headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
            }
            selected_headers = info.get('http_headers') or default_headers
            
            if not selected_url:
                formats = info.get('formats', [])
                audio_formats = [
                    f for f in formats
                    if (f.get('acodec') != 'none' and 
                        f.get('url') and 
                        'manifest' not in f['url'].lower() and
                        '.m3u8' not in f['url'].lower())
                ]
                if audio_formats:
                    audio_formats.sort(key=lambda f: f.get('abr', 0) or f.get('tbr', 0) or 0, reverse=True)
                    best_fmt = audio_formats[0]
                    selected_url = best_fmt['url']
                    if best_fmt.get('http_headers'):
                        selected_headers = best_fmt['http_headers']
            
            if selected_url:
                import json
                return json.dumps({
                    "url": selected_url,
                    "headers": selected_headers,
                    "format_id": info.get('format_id', ''),
                    "ext": info.get('ext', 'm4a'),
                    "abr": info.get('abr', 0)
                })
            
            return None
            
        except Exception as e:
            print(f"Audio extraction failed for {video_id}: {e}")
            return None

    def _get_ytmusic_stream(self, video_id: str) -> Optional[str]:
        """Try to get high quality stream directly from YouTube Music"""
        try:
            song_info = self.ytmusic.get_song(video_id)
            if song_info:
                # Check for streaming data in the song info
                streaming_data = song_info.get('streamingData', {})
                if streaming_data:
                    # Prefer adaptive formats for higher quality
                    formats = streaming_data.get('adaptiveFormats', [])
                    for fmt in formats:
                        if fmt.get('mimeType', '').startswith('audio/'):
                            return fmt.get('url')
        except Exception as e:
            print(f"⚠️ YouTube Music stream fetch failed: {str(e)}")
        return None

    def _get_quality_label(self, fmt: dict) -> str:
        """Determine quality label based on format properties"""
        bitrate = fmt.get('abr', 0) or fmt.get('tbr', 0) or 0
        codec = (fmt.get('acodec') or '').lower()
        
        if bitrate >= 256 or 'opus' in codec:
            return "HIGH"
        elif bitrate >= 128:
            return "MEDIUM"
        return "LOW"
    
    def get_hq_album_art_from_ytdlp(self, video_id: str) -> Optional[str]:
        """
        Get high quality album art using yt-dlp from video metadata
        Returns the highest quality album art URL available
        """
        try:
            ydl_opts = {
                "quiet": True,
                "no_warnings": True,
                "skip_download": True,
                "nocheckcertificate": True,
                "extract_flat": False,
                "socket_timeout": 30,
                "source_address": "0.0.0.0",
                "force_ipv4": True,
                "retries": 2,
                "headers": self._generate_headers()
            }
            
            if self.proxy:
                ydl_opts["proxy"] = self.proxy
                ydl_opts["proxy_headers"] = ydl_opts["headers"]
            
            ydl = yt_dlp.YoutubeDL(ydl_opts)
            
            info = ydl.extract_info(
                f"https://www.youtube.com/watch?v={video_id}",
                download=False
            )
            
            # First try to get album art from metadata
            album_art_url = None
            
            # Check for album art in various metadata fields
            if info.get('album_artist') and info.get('album'):
                # Try to construct album art URL from metadata
                album_art_url = self._get_album_art_from_metadata(info)
            
            # If no album art from metadata, fall back to high quality thumbnails
            if not album_art_url:
                thumbnails = info.get('thumbnails', [])
                if thumbnails:
                    # Filter for high quality thumbnails (prefer square ones for album art)
                    hq_thumbnails = [
                        t for t in thumbnails 
                        if t.get('width', 0) >= 720 and t.get('height', 0) >= 720
                    ]
                    
                    if hq_thumbnails:
                        # Sort by resolution and prefer square aspect ratios
                        hq_thumbnails.sort(
                            key=lambda t: (
                                abs(1.0 - (t.get('width', 1) / t.get('height', 1))),  # Prefer square
                                (t.get('width', 0) * t.get('height', 0))  # Then by resolution
                            ),
                            reverse=True
                        )
                        album_art_url = hq_thumbnails[0].get('url', '')
                    else:
                        # Fall back to highest resolution thumbnail
                        thumbnails.sort(
                            key=lambda t: (t.get('width', 0) * t.get('height', 0)),
                            reverse=True
                        )
                        album_art_url = thumbnails[0].get('url', '')
            
            if album_art_url:
                print(f"PythonEngine: HQ Album Art found: {album_art_url}")
                return album_art_url
            
            return None
            
        except Exception as e:
            print(f"PythonEngineExceptionsCritical: Error getting HQ album art for {video_id}: {e}")
            return None

    def _get_album_art_from_metadata(self, info: dict) -> Optional[str]:
        """
        Try to get album art from video metadata
        """
        try:
            # Check for album art in various metadata fields
            album_art_fields = ['album_art', 'album_artwork', 'artwork', 'cover']
            
            for field in album_art_fields:
                if info.get(field):
                    return info[field]
            
            # Try to get from uploader avatar if it's an official channel
            uploader = info.get('uploader', '').lower()
            if any(keyword in uploader for keyword in ['official', 'records', 'music', 'vevo']):
                uploader_avatar = info.get('uploader_avatar_url')
                if uploader_avatar:
                    return uploader_avatar
            
            return None
            
        except Exception:
            return None

    def get_youtube_music_album_art(self, video_id: str) -> Optional[str]:
        """
        Get album art specifically from YouTube Music metadata
        """
        try:
            # Use YTMusic to get song details which might have better album art
            song_info = self.ytmusic.get_song(video_id)
            
            # Extract album art from song info
            thumbnails = song_info.get('videoDetails', {}).get('thumbnail', {}).get('thumbnails', [])
            
            if thumbnails:
                # Sort by resolution to get highest quality
                thumbnails.sort(
                    key=lambda t: (t.get('width', 0) * t.get('height', 0)),
                    reverse=True
                )
                
                # Prefer square thumbnails for album art
                square_thumbnails = [
                    t for t in thumbnails 
                    if abs(1.0 - (t.get('width', 1) / t.get('height', 1))) < 0.1
                ]
                
                if square_thumbnails:
                    return square_thumbnails[0].get('url', '')
                else:
                    return thumbnails[0].get('url', '')
            
            return None
            
        except Exception as e:
            print(f"Error getting YouTube Music album art for {video_id}: {e}")
            return None

    def _find_song_video_id(self, song_name: str, artist_name: str) -> Optional[str]:
        query = f"{song_name} {artist_name}"
        
        for attempt in range(3):
            try:
                results = self.ytmusic.search(query, filter="songs", limit=10)
                
                for item in results:
                    title = item.get("title", "").lower()
                    artists = [a.get("name", "").lower() for a in item.get("artists", [])]
                    
                    if any(word in title for word in song_name.lower().split()):
                        if any(artist_name.lower() in artist for artist in artists):
                            return item.get("videoId")
                
                if results:
                    return results[0].get("videoId")
                    
            except Exception:
                if attempt == 2:
                    return None
                time.sleep(2 ** attempt)
                self._initialize_ytmusic()
        
        return None

    def get_video_info(self, video_id: str) -> Optional[dict]:
        try:
            song_info = self.ytmusic.get_song(video_id)
            watch_playlist = self.ytmusic.get_watch_playlist(video_id)
            
            return {
                "song_info": song_info,
                "related_tracks": watch_playlist.get("tracks", [])
            }
            
        except Exception as e:
            print(f"Error getting video info for {video_id}: {str(e)}")
            return None
        
    def getRelated(
        self,
        song_name: str,
        artist_name: str,
        limit: int = 100,
        thumb_quality: str = "VERY_HIGH",
        audio_quality: str = "HIGH",
        include_audio_url: bool = True,
        include_album_art: bool = True
    ) -> Generator[dict, None, None]:
        import re
        import time

        inspector = SearchInspector.get_instance()
        search_id = f"related_{hash(song_name + artist_name)}_{int(time.time())}"

        def generate_logic():
            if not song_name.strip() or not artist_name.strip():
                return

            if not inspector.is_active(search_id):
                return

            print(f"[{search_id}] 🔍 Looking up video ID: {song_name} by {artist_name}")
            video_id = self._find_song_video_id(song_name, artist_name)
            if not video_id or not inspector.is_active(search_id):
                return

            video_info = self.get_video_info(video_id)
            if not video_info or not video_info.get("related_tracks"):
                return

            related_tracks = video_info["related_tracks"]
            processed_count = 0
            print(f"[{search_id}] 🎧 Streaming up to {limit} related tracks")

            for item in related_tracks:
                if processed_count >= limit:
                    break
                if not inspector.is_active(search_id):
                    return

                track_id = item.get("videoId")
                if not track_id or track_id == video_id:
                    continue

                title = item.get("title", "Unknown Title")
                artists = ", ".join(a.get("name", "Unknown") for a in item.get("artists", [])) or "Unknown"
                duration = item.get("length", "N/A")

                album_art = ""
                if include_album_art and inspector.is_active(search_id):
                    try:
                        album_art = self.get_youtube_music_album_art(track_id) or ""
                        # fallback
                        if not album_art:
                            thumbnails = item.get("thumbnail", [])
                            if thumbnails:
                                base_url = thumbnails[-1].get("url", "")
                                if thumb_quality == ThumbnailQuality.HIGH:
                                    album_art = re.sub(r'w\d+-h\d+', 'w320-h320', base_url)
                                else:
                                    album_art = re.sub(r'w\d+-h\d+', 'w544-h544', base_url)
                    except Exception:
                        pass

                audio_url = None
                if include_audio_url:
                    for _ in range(3):
                        if not inspector.is_active(search_id):
                            return
                        audio_url = self.get_audio_url(track_id, audio_quality)
                        if audio_url:
                            break
                        time.sleep(1)

                if not inspector.is_active(search_id):
                    return

                if not include_audio_url or audio_url:
                    song = {
                        "title": title,
                        "artists": artists,
                        "videoId": track_id,
                        "duration": duration,
                        "isOriginal": False
                    }
                    if include_album_art:
                        song["albumArt"] = album_art
                    if include_audio_url:
                        song["audioUrl"] = audio_url

                    if not inspector.is_active(search_id):
                        return

                    processed_count += 1
                    print(f"[{search_id}] ✅ Yielding related track {processed_count}: {title}")
                    yield song

        def generator():
            yield from generate_logic()

        gen = generator()
        inspector.register_search(search_id, "related_songs", gen)

        try:
            yield from gen
        finally:
            inspector.cancel_search(search_id)

    def RelatedStreamCleanup(self):
        """Clean up resources"""
        try:
            if hasattr(self, 'yt_music'):
                del self.yt_music
            if hasattr(self, 'yt_dlp'):
                del self.yt_dlp
            # Clear any cached data
            if hasattr(self, '_cache'):
                self._cache.clear()
        except Exception as e:
            print(f"YTMusicRelatedFetcher cleanup error: {e}")


class LyricsProcessor:
    """Lyrics processor uses levenshtein_distance."""
    
    def __init__(self):
        self.instrumental_markers = {
            'instrumental', 'outro', 'intro', 'bridge', 'solo', 'interlude',
            'breakdown', 'drop', 'beat', 'music', 'melody', 'tune'
        }
        
        self.section_markers = {
            'verse', 'chorus', 'bridge', 'outro', 'intro', 'pre-chorus',
            'hook', 'refrain', 'breakdown', 'interlude'
        }
        
        self.stop_words = {
            'ft', 'feat', 'featuring', 'remix', 'edit', 'version', 'official',
            'video', 'audio', 'remastered', 'deluxe', 'extended', 'radio'
        }

    def levenshtein_distance(self, s1: str, s2: str) -> int:
        """Calculate Levenshtein distance between two strings (pure Python)."""
        if len(s1) < len(s2):
            return self.levenshtein_distance(s2, s1)
        
        if len(s2) == 0:
            return len(s1)
        
        previous_row = list(range(len(s2) + 1))
        for i, c1 in enumerate(s1):
            current_row = [i + 1]
            for j, c2 in enumerate(s2):
                insertions = previous_row[j + 1] + 1
                deletions = current_row[j] + 1
                substitutions = previous_row[j] + (c1 != c2)
                current_row.append(min(insertions, deletions, substitutions))
            previous_row = current_row
        
        return previous_row[-1]

    def similarity_ratio(self, s1: str, s2: str) -> float:
        """Calculate similarity ratio between two strings (0-100)."""
        if not s1 and not s2:
            return 100.0
        if not s1 or not s2:
            return 0.0
        
        max_len = max(len(s1), len(s2))
        distance = self.levenshtein_distance(s1.lower(), s2.lower())
        return ((max_len - distance) / max_len) * 100

    def clean_string(self, text: str) -> str:
        """Clean a string for better matching."""
        if not text:
            return ""
            
        text = text.lower().strip()
        text = re.sub(r'\([^)]*\)', '', text)
        text = re.sub(r'\[[^\]]*\]', '', text)
        text = re.sub(r'[^\w\s\-]', ' ', text)
        text = re.sub(r'\s+', ' ', text)
        
        words = text.split()
        words = [word for word in words if word not in self.stop_words and len(word) > 1]
        
        return ' '.join(words).strip()

    def calculate_match_score(self, result: Dict, target_title: str, target_artist: str) -> float:
        """Calculate relevance score for a search result."""
        score = 0.0
        
        result_title = result.get('title', '')
        result_artists = [a.get('name', '') for a in result.get('artists', [])]
        
        clean_target_title = self.clean_string(target_title)
        clean_result_title = self.clean_string(result_title)
        clean_target_artist = self.clean_string(target_artist)
        
        # Title matching
        if clean_target_title and clean_result_title:
            if clean_target_title == clean_result_title:
                score += 50
            elif clean_target_title in clean_result_title or clean_result_title in clean_target_title:
                score += 40
            else:
                title_similarity = self.similarity_ratio(clean_target_title, clean_result_title)
                score += (title_similarity / 100) * 35
        
        # Artist matching
        best_artist_score = 0
        for result_artist in result_artists:
            clean_result_artist = self.clean_string(result_artist.get('name', ''))
            
            if clean_target_artist and clean_result_artist:
                if clean_target_artist == clean_result_artist:
                    best_artist_score = 40
                    break
                elif clean_target_artist in clean_result_artist or clean_result_artist in clean_target_artist:
                    best_artist_score = max(best_artist_score, 30)
                else:
                    artist_similarity = self.similarity_ratio(clean_target_artist, clean_result_artist)
                    if artist_similarity > 70:
                        best_artist_score = max(best_artist_score, (artist_similarity / 100) * 25)
        
        score += best_artist_score
        
        if result.get('resultType') == 'song':
            score += 10
        
        return min(score, 100.0)

    def is_instrumental_line(self, line: str) -> bool:
        """Check if a line indicates instrumental content."""
        line_lower = line.lower().strip()
        
        for marker in self.instrumental_markers:
            if marker in line_lower:
                return True
        
        if re.match(r'^[^\w]*$', line_lower):
            return True
        
        words = line_lower.split()
        if len(words) >= 3:
            unique_words = set(words)
            if len(unique_words) <= 2 and all(len(word) <= 3 for word in unique_words):
                return True
        
        return False

    def detect_section_type(self, line: str) -> str:
        """Detect what type of section a line represents."""
        line_lower = line.lower().strip()
        
        for section in self.section_markers:
            if line_lower.startswith(f'[{section}') or line_lower.startswith(f'({section}'):
                return section
            if line_lower == section or line_lower.startswith(f'{section}:'):
                return section
        
        if any(word in line_lower for word in ['chorus', 'hook', 'refrain']):
            return 'chorus'
        
        if any(word in line_lower for word in ['verse', 'stanza']):
            return 'verse'
        
        return 'lyric'

    def is_section_marker(self, line: str) -> bool:
        """Check if line is a section marker rather than actual lyrics."""
        section_type = self.detect_section_type(line)
        return section_type in self.section_markers

    def analyze_lyrics_quality(self, raw_lyrics: str) -> Dict[str, Any]:
        """Analyze the quality and characteristics of lyrics."""
        if not raw_lyrics:
            return {
                'is_instrumental': True,
                'quality_score': 0,
                'line_count': 0,
                'lyrical_line_count': 0,
                'has_structure': False
            }
        
        lines = [line.strip() for line in raw_lyrics.split('\n') if line.strip()]
        
        lyrical_lines = 0
        instrumental_lines = 0
        section_markers = 0
        
        for line in lines:
            if self.is_instrumental_line(line):
                instrumental_lines += 1
            elif self.is_section_marker(line):
                section_markers += 1
            else:
                lyrical_lines += 1
        
        total_lines = len(lines)
        quality_score = 0
        if total_lines > 0:
            lyrical_ratio = lyrical_lines / total_lines
            quality_score = lyrical_ratio * 100
        
        is_instrumental = (instrumental_lines > lyrical_lines) or (lyrical_lines < 5)
        
        return {
            'is_instrumental': is_instrumental,
            'quality_score': quality_score,
            'line_count': total_lines,
            'lyrical_line_count': lyrical_lines,
            'instrumental_line_count': instrumental_lines,
            'section_marker_count': section_markers,
            'has_structure': section_markers > 0
        }

    def process_lyrics(self, raw_lyrics: str) -> List[Dict[str, Any]]:
        """Process raw lyrics into structured format with analysis."""
        if not raw_lyrics:
            return []
        
        lines = []
        current_section = 'verse'
        
        for line_num, line in enumerate(raw_lyrics.split('\n')):
            line = line.strip()
            
            if not line:
                continue
            
            if self.is_instrumental_line(line):
                continue
            
            if self.is_section_marker(line):
                current_section = self.detect_section_type(line)
                lines.append({
                    'timestamp': -1,
                    'text': line,
                    'time_formatted': '',
                    'line_number': line_num,
                    'section_type': 'marker',
                    'section': current_section,
                    'is_instrumental': False,
                    'is_section_marker': True
                })
                continue
            
            section_type = self.detect_section_type(line)
            if section_type in self.section_markers:
                current_section = section_type
            
            lines.append({
                'timestamp': -1,
                'text': line,
                'time_formatted': '',
                'line_number': line_num,
                'section_type': 'lyric',
                'section': current_section,
                'is_instrumental': False,
                'is_section_marker': False
            })
        
        return lines





# =================================================================================================================================
# =================================================================================================================================



# Global instance for easy access



# # Helper functions for common operations
# def register_search(search_id: Optional[str] = None, 
#                    search_type: Optional[str] = None, 
#                    generator: Optional[Generator] = None) -> str:
#     """Convenience function to register a search"""
#     return search_inspector.register_search(search_id, search_type, generator)


# def cancel_search(search_id: str) -> bool:
#     """Convenience function to cancel a search"""
#     return search_inspector.cancel_search(search_id)


# def cancel_search_type(search_type: str) -> int:
#     """Convenience function to cancel all searches of a type"""
#     return search_inspector.cancel_type(search_type)


# def is_search_active(search_id: str) -> bool:
#     """Convenience function to check if a search is active"""
#     return search_inspector.is_active(search_id)


# def cleanup_stale_searches(timeout: int = 300) -> int:
#     """Convenience function to cleanup stale searches"""
#     return search_inspector.cleanup_stale(timeout)


# class DynamicLyricsProvider:
#     """
#     A dynamic lyrics provider that fetches lyrics with timestamps from KuGou.
#     Designed for Flutter/Kotlin integration to provide real-time lyrics display.
#     """
    
#     PAGE_SIZE = 8
#     HEAD_CUT_LIMIT = 30
#     DURATION_TOLERANCE = 8
#     ACCEPTED_REGEX = re.compile(r"\[(\d\d):(\d\d)\.(\d{2,3})\].*")
#     BANNED_REGEX = re.compile(r".+].+[:：].+")
    
#     def __init__(self):
#         self.session = requests.Session()
#         self.session.headers.update({
#             'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
#         })
    
#     def normalize_title(self, title: str) -> str:
#         """Clean title for better search results"""
#         return re.sub(r'\(.*\)|（.*）|「.*」|『.*』|<.*>|《.*》|〈.*〉|＜.*＞', '', title).strip()
    
#     def normalize_artist(self, artist: str) -> str:
#         """Clean artist name for better search results"""
#         artist = re.sub(r', | & |\.|和', '、', artist)
#         return re.sub(r'\(.*\)|（.*）', '', artist).strip()
    
#     def generate_keyword(self, title: str, artist: str) -> Dict[str, str]:
#         """Generate search keywords from title and artist"""
#         return {
#             'title': self.normalize_title(title),
#             'artist': self.normalize_artist(artist)
#         }
    
#     def normalize_lyrics(self, lyrics: str) -> str:
#         """Clean and filter lyrics to keep only timestamped lines"""
#         lyrics = lyrics.replace("&apos;", "'")
#         lines = [line for line in lyrics.split('\n') if self.ACCEPTED_REGEX.match(line)]
        
#         # Remove useless info from beginning
#         head_cut_line = 0
#         for i in range(min(self.HEAD_CUT_LIMIT, len(lines)-1), -1, -1):
#             if self.BANNED_REGEX.match(lines[i]):
#                 head_cut_line = i + 1
#                 break
#         filtered_lines = lines[head_cut_line:]
        
#         # Remove useless info from end
#         tail_cut_line = 0
#         for i in range(min(len(lines)-self.HEAD_CUT_LIMIT, len(lines)-1), -1, -1):
#             if self.BANNED_REGEX.match(lines[len(lines)-1-i]):
#                 tail_cut_line = i + 1
#                 break
#         final_lines = filtered_lines[:len(filtered_lines)-tail_cut_line] if tail_cut_line > 0 else filtered_lines
        
#         return '\n'.join(final_lines)
    
#     def search_songs(self, keyword: Dict[str, str]) -> Dict[str, Any]:
#         """Search for songs on KuGou to get hash"""
#         url = "https://mobileservice.kugou.com/api/v3/search/song"
#         params = {
#             'version': 9108,
#             'plat': 0,
#             'pagesize': self.PAGE_SIZE,
#             'showtype': 0,
#             'keyword': f"{keyword['title']} - {keyword['artist']}"
#         }
#         try:
#             response = self.session.get(url, params=params, timeout=10)
#             return response.json()
#         except Exception as e:
#             print(f"Error searching songs: {e}")
#             return {}
    
#     def search_lyrics_by_keyword(self, keyword: Dict[str, str], duration: int = -1) -> Dict[str, Any]:
#         """Search for lyrics by keyword"""
#         url = "https://lyrics.kugou.com/search"
#         params = {
#             'ver': 1,
#             'man': 'yes',
#             'client': 'pc',
#             'keyword': f"{keyword['title']} - {keyword['artist']}"
#         }
#         if duration != -1:
#             params['duration'] = duration * 1000
        
#         try:
#             response = self.session.get(url, params=params, timeout=10)
#             return response.json()
#         except Exception as e:
#             print(f"Error searching lyrics by keyword: {e}")
#             return {}
    
#     def search_lyrics_by_hash(self, hash: str) -> Dict[str, Any]:
#         """Search for lyrics by song hash"""
#         url = "https://lyrics.kugou.com/search"
#         params = {
#             'ver': 1,
#             'man': 'yes',
#             'client': 'pc',
#             'hash': hash
#         }
#         try:
#             response = self.session.get(url, params=params, timeout=10)
#             return response.json()
#         except Exception as e:
#             print(f"Error searching lyrics by hash: {e}")
#             return {}
    
#     def download_lyrics(self, id: str, accesskey: str) -> Dict[str, Any]:
#         """Download lyrics content"""
#         url = "https://lyrics.kugou.com/download"
#         params = {
#             'fmt': 'lrc',
#             'charset': 'utf8',
#             'client': 'pc',
#             'ver': 1,
#             'id': id,
#             'accesskey': accesskey
#         }
#         try:
#             response = self.session.get(url, params=params, timeout=10)
#             return response.json()
#         except Exception as e:
#             print(f"Error downloading lyrics: {e}")
#             return {}
    
#     def parse_lrc_timestamps(self, lyrics: str) -> List[Dict[str, Any]]:
#         """Parse LRC format and convert to structured format for Flutter"""
#         lines = []
#         for line in lyrics.split('\n'):
#             match = self.ACCEPTED_REGEX.match(line)
#             if match:
#                 minutes = int(match.group(1))
#                 seconds = int(match.group(2))
#                 milliseconds = int(match.group(3).ljust(3, '0')[:3])  # Ensure 3 digits
                
#                 timestamp_ms = (minutes * 60 * 1000) + (seconds * 1000) + milliseconds
#                 text = line.split(']', 1)[1].strip() if ']' in line else ""
                
#                 if text:  # Only add non-empty lines
#                     lines.append({
#                         'timestamp': timestamp_ms,
#                         'text': text,
#                         'time_formatted': f"{minutes:02d}:{seconds:02d}.{milliseconds:03d}"
#                     })
        
#         return sorted(lines, key=lambda x: x['timestamp'])
    
#     def fetch_lyrics(self, title: str, artist: str, duration: int = -1) -> Optional[Dict[str, Any]]:
#         """
#         Main method to fetch lyrics with timestamps.
#         Returns simplified structured data suitable for Flutter/Kotlin integration.
#         """
#         print(f"Starting lyrics fetch for: {title} by {artist}")
        
#         keyword = self.generate_keyword(title, artist)
#         print(f"Generated keyword: {keyword}")

#         # First try searching by song hash
#         print("Searching songs by keyword...")
#         songs = self.search_songs(keyword)
#         print(f"Found {len(songs.get('data', {}).get('info', []))} song matches")

#         for song in songs.get('data', {}).get('info', []):
#             try:
#                 if duration == -1 or abs(song['duration'] - duration) <= self.DURATION_TOLERANCE:
#                     print(f"Trying song hash: {song['hash']}")
#                     lyrics_data = self.search_lyrics_by_hash(song['hash'])
#                     print(f"Lyrics search result: {lyrics_data}")

#                     if lyrics_data.get('candidates'):
#                         candidate = lyrics_data['candidates'][0]
#                         print(f"Downloading lyrics for candidate: {candidate}")
#                         lyrics = self.download_lyrics(candidate['id'], candidate['accesskey'])
#                         print(f"Downloaded lyrics content: {lyrics.get('content') is not None}")

#                         if lyrics.get('content'):
#                             try:
#                                 content = base64.b64decode(lyrics['content']).decode('utf-8')
#                                 normalized = self.normalize_lyrics(content)
#                                 print(f"Normalized lyrics length: {len(normalized)} chars")

#                                 if "纯音乐，请欣赏" in normalized or "酷狗音乐  就是歌多" in normalized:
#                                     print("Skipping instrumental track")
#                                     continue
                                
#                                 parsed_lyrics = self.parse_lrc_timestamps(normalized)
#                                 print(f"Parsed {len(parsed_lyrics)} lyrics lines")

#                                 if parsed_lyrics:
#                                     return {
#                                         'success': True,
#                                         'lyrics': parsed_lyrics,
#                                         'source': 'KuGou',
#                                         'total_lines': len(parsed_lyrics)
#                                     }
#                             except Exception as e:
#                                 print(f"Error processing lyrics: {e}")
#                                 continue
#             except Exception as e:
#                 print(f"Error processing song: {e}")
#                 continue

#         # If not found, try searching by keyword
#         print("Trying lyrics search by keyword...")
#         lyrics_data = self.search_lyrics_by_keyword(keyword, duration)
#         print(f"Keyword search result: {lyrics_data}")

#         if lyrics_data.get('candidates'):
#             candidate = lyrics_data['candidates'][0]
#             print(f"Downloading lyrics for keyword candidate: {candidate}")
#             lyrics = self.download_lyrics(candidate['id'], candidate['accesskey'])
#             print(f"Downloaded lyrics content: {lyrics.get('content') is not None}")

#             if lyrics.get('content'):
#                 try:
#                     content = base64.b64decode(lyrics['content']).decode('utf-8')
#                     normalized = self.normalize_lyrics(content)
#                     print(f"Normalized lyrics length: {len(normalized)} chars")

#                     if "纯音乐，请欣赏" in normalized or "酷狗音乐  就是歌多" in normalized:
#                         print("Returning not found for instrumental track")
#                         return {
#                             'success': False,
#                             'error': f'No lyrics found for {title} by {artist}'
#                         }
                    
#                     parsed_lyrics = self.parse_lrc_timestamps(normalized)
#                     print(f"Parsed {len(parsed_lyrics)} lyrics lines")

#                     if parsed_lyrics:
#                         return {
#                             'success': True,
#                             'lyrics': parsed_lyrics,
#                             'source': 'KuGou',
#                             'total_lines': len(parsed_lyrics)
#                         }
#                 except Exception as e:
#                     print(f"Error processing lyrics: {e}")

#         print("No lyrics found after all attempts")
#         return {
#             'success': False,
#             'error': f'No lyrics found for {title} by {artist}'
#         }

# Test examples
# if __name__ == "__main__":
# #     # Initialize both services
# #     print("Initializing services...")
# #     searcher = YTMusicSearcher(country="US")
# #     related_fetcher = YTMusicRelatedFetcher(country="US")
#     searcher = YTMusicSearcher(country="US")

#     # Single song lookup
#     # song_details = searcher.get_song_details(
#     #     songs=[{"song_name": "Blinding Lights", "artist_name": "The Weeknd"}],
#     #     mode="single"
#     # )

#     # if song_details:
#     #     print(f"Title: {song_details['title']}")
#     #     print(f"Artists: {song_details['artists']}")
#     # print("Single Mode: Results Ready")
    

#     # Batch processing
#     songs_to_lookup = [
#         {"song_name": "Viva La Vida", "artist_name": "Coldplay"},
#         {"song_name": "Shape of You", "artist_name": "Ed Sheeran"}
#     ]

#     for song in searcher.get_song_details(
#         songs=songs_to_lookup,
#         mode="batch"
#     ):
#         # print(f"\n{song['title']} by {song['artists']}")
#         print("Batch Mode: Results Ready")



#     # Test search functionality
#     print("\n=== Testing Search Functionality ===")
#     test_query = "Gale Lag Ja"
#     print(f"Searching for: {test_query}")
    
#     for i, song in enumerate(searcher.get_music_details(test_query, limit=3), 1):
#         print(f"\n{i}. {song['title']} by {song['artists']}")
#         print(f"Duration: {song.get('duration', 'N/A')}")
#         if 'albumArt' in song:
#             print(f"Album Art: {song['albumArt']}")
#         if 'audioUrl' in song:
#             print(f"Audio URL: {song['audioUrl'][:50]}...")  # Print first 50 chars of URL
    
#     # Test related songs functionality
#     print("\n=== Testing Related Songs Functionality ===")
#     test_song = "Viva La Vida"
#     test_artist = "Coldplay"
#     print(f"Finding related songs for: {test_song} by {test_artist}")
    
#     for i, song in enumerate(related_fetcher.getRelated(
#         song_name=test_song,
#         artist_name=test_artist,
#         limit=3,
#         include_audio_url=False  # Faster testing without audio URLs
#     ), 1):
#         print(f"\n{i}. {song['title']} by {song['artists']}")
#         print(f"Duration: {song.get('duration', 'N/A')}")
#         if 'albumArt' in song:
#             print(f"Album Art: {song['albumArt']}")
#         print(f"Is Original: {song.get('isOriginal', False)}")
    
#     print("\nTests completed successfully!")



    
