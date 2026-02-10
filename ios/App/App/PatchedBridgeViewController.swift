import UIKit
import WebKit
import Capacitor

/// Custom CAPBridgeViewController that injects client-side patches into the remote
/// Base44 WebView to fix production issues:
///   A) ErrorBoundary — catches React "must be used within" errors (SelectTrigger)
///   B) Duplicate back-button removal
///   C) Missing back-button injection on Captain's Log / More
///   D) Bottom-nav layout fix for 5-tab mode (Prayer Wall enabled)
///   E) Safe-area padding for iOS status bar / home indicator
class PatchedBridgeViewController: CAPBridgeViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        injectPatches()
    }

    // MARK: – Script injection

    private func injectPatches() {
        guard let webView = self.webView else { return }
        let controller = webView.configuration.userContentController

        // Inject CSS fixes
        let cssScript = WKUserScript(
            source: Self.cssInjection,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(cssScript)

        // Inject JS fixes (error boundary, DOM patches)
        let jsScript = WKUserScript(
            source: Self.jsInjection,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(jsScript)
    }

    // MARK: – CSS Patch

    private static let cssInjection: String = """
    (function() {
      var style = document.createElement('style');
      style.id = 'aa-ios-patches';
      style.textContent = `
        /* ── Bottom nav: ensure min tap-target and no squash with 5 tabs ── */
        nav.fixed.bottom-0 .flex.items-center.justify-around > a {
          min-width: 48px !important;
          padding-left: 4px !important;
          padding-right: 4px !important;
          flex: 1 1 0% !important;
        }
        nav.fixed.bottom-0 .flex.items-center.justify-around > a .w-5 {
          width: 22px !important;
          height: 22px !important;
        }
        nav.fixed.bottom-0 .flex.items-center.justify-around > a .text-xs {
          font-size: 10px !important;
          line-height: 1.2 !important;
          white-space: nowrap !important;
          overflow: hidden !important;
          text-overflow: ellipsis !important;
          max-width: 56px !important;
        }

        /* ── Safe-area bottom padding for nav ── */
        nav.fixed.bottom-0 {
          padding-bottom: max(env(safe-area-inset-bottom, 0px), 8px) !important;
        }

        /* ── ErrorBoundary fallback styling ── */
        .aa-error-fallback {
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          min-height: 60vh;
          padding: 24px;
          text-align: center;
          font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        }
        .aa-error-fallback h2 {
          font-size: 20px;
          color: #1e293b;
          margin-bottom: 8px;
        }
        .aa-error-fallback p {
          font-size: 14px;
          color: #64748b;
          margin-bottom: 16px;
        }
        .aa-error-fallback button {
          padding: 10px 24px;
          background: #c9a96e;
          color: #0b1f2a;
          border: none;
          border-radius: 8px;
          font-size: 15px;
          font-weight: 600;
          cursor: pointer;
        }
      `;
      document.head.appendChild(style);
    })();
    """

    // MARK: – JS Patch

    private static let jsInjection: String = """
    (function() {
      'use strict';

      // ── 1. Global error handler — prevent white screens ──
      window.addEventListener('error', function(event) {
        var msg = (event.error && event.error.message) || event.message || '';
        if (msg.indexOf('must be used within') !== -1 ||
            msg.indexOf('Cannot read properties of null') !== -1) {
          event.preventDefault();
          showErrorFallback(msg);
        }
      });

      window.addEventListener('unhandledrejection', function(event) {
        var msg = (event.reason && event.reason.message) || String(event.reason || '');
        if (msg.indexOf('must be used within') !== -1) {
          event.preventDefault();
          showErrorFallback(msg);
        }
      });

      function showErrorFallback(msg) {
        // Find the main content area (skip the nav bar)
        var mainContent = document.querySelector('main') ||
                          document.querySelector('[class*="min-h-screen"]') ||
                          document.getElementById('root');
        if (!mainContent) return;

        // Only inject fallback if there's an error (don't replace working content)
        // Check if the page is actually blank/broken
        var visibleContent = mainContent.innerText.trim();
        if (visibleContent.length > 50) return; // Page has content, don't override

        // Create fallback UI
        var fallback = document.createElement('div');
        fallback.className = 'aa-error-fallback';
        fallback.innerHTML =
          '<h2>Something went wrong</h2>' +
          '<p>This page encountered an issue. Tap below to go back.</p>' +
          '<button onclick="window.history.back()">Go Back</button>' +
          '<br/><button onclick="window.location.href=\\'/\\'" style="margin-top:8px;background:#e2e8f0;color:#334155;">Go Home</button>';

        // Insert after existing content
        mainContent.appendChild(fallback);
      }

      // ── 2. MutationObserver for DOM fixes ──
      var patchTimer = null;
      function runDOMPatches() {
        if (patchTimer) return;
        patchTimer = setTimeout(function() {
          patchTimer = null;
          fixDuplicateBackButtons();
          fixMissingBackButtons();
        }, 200);
      }

      // ── 2a. Remove duplicate back buttons ──
      function fixDuplicateBackButtons() {
        // Find all elements that look like back buttons in headers
        var headers = document.querySelectorAll('header, [class*="sticky top"], [class*="fixed top"]');
        headers.forEach(function(header) {
          var backBtns = [];
          var btns = header.querySelectorAll('button, a');
          btns.forEach(function(btn) {
            var text = (btn.textContent || '').trim().toLowerCase();
            // Match "back", "← back", chevron-left icons, ArrowLeft
            if (text === 'back' || text === '← back' || text === '‹ back') {
              backBtns.push(btn);
            } else if (btn.querySelector('svg') && !btn.querySelector('svg ~ span') &&
                       btn.getAttribute('aria-label') &&
                       btn.getAttribute('aria-label').toLowerCase().indexOf('back') !== -1) {
              backBtns.push(btn);
            }
          });
          // Keep the first, hide duplicates
          for (var i = 1; i < backBtns.length; i++) {
            backBtns[i].style.display = 'none';
          }
        });

        // Also check for multiple adjacent "Back" elements outside headers
        var allBtns = document.querySelectorAll('button, a');
        var prevWasBack = false;
        allBtns.forEach(function(btn) {
          var text = (btn.textContent || '').trim().toLowerCase();
          if (text === 'back' || text === '← back') {
            if (prevWasBack) {
              btn.style.display = 'none';
            }
            prevWasBack = true;
          } else {
            prevWasBack = false;
          }
        });
      }

      // ── 2b. Add back button where missing ──
      function fixMissingBackButtons() {
        var path = window.location.pathname.toLowerCase();
        var needsBack = path.indexOf('/journal') !== -1 ||
                        path.indexOf('/more') !== -1;
        if (!needsBack) return;

        // Check if a back button already exists
        var header = document.querySelector('header, [class*="sticky top"]');
        if (!header) return;

        var hasBack = false;
        var btns = header.querySelectorAll('button, a');
        btns.forEach(function(btn) {
          var text = (btn.textContent || '').trim().toLowerCase();
          if (text.indexOf('back') !== -1 || (btn.getAttribute('aria-label') || '').toLowerCase().indexOf('back') !== -1) {
            if (btn.style.display !== 'none') hasBack = true;
          }
        });

        if (hasBack) return;

        // Only inject if there's an actual header to attach to and it looks like a page header
        // (not the admin bar or other fixed elements)
        if (header.querySelector('.aa-injected-back')) return;

        var backBtn = document.createElement('button');
        backBtn.className = 'aa-injected-back';
        backBtn.setAttribute('aria-label', 'Back');
        backBtn.style.cssText = 'background:none;border:none;color:inherit;font-size:15px;font-weight:500;padding:8px 12px;cursor:pointer;display:flex;align-items:center;gap:4px;min-height:44px;min-width:44px;';
        backBtn.innerHTML = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"></polyline></svg><span>Back</span>';
        backBtn.addEventListener('click', function() { window.history.back(); });

        // Insert at the beginning of the header
        header.insertBefore(backBtn, header.firstChild);
      }

      // ── 3. Start observer ──
      var observer = new MutationObserver(function(mutations) {
        var shouldPatch = false;
        for (var i = 0; i < mutations.length; i++) {
          if (mutations[i].addedNodes.length > 0 || mutations[i].removedNodes.length > 0) {
            shouldPatch = true;
            break;
          }
        }
        if (shouldPatch) runDOMPatches();
      });

      // Start observing once the root is ready
      function startObserving() {
        var root = document.getElementById('root');
        if (root) {
          observer.observe(root, { childList: true, subtree: true });
          // Run initial patches
          runDOMPatches();
        } else {
          setTimeout(startObserving, 100);
        }
      }

      // Also run on popstate (SPA navigation)
      window.addEventListener('popstate', function() {
        setTimeout(runDOMPatches, 300);
      });

      // Intercept history.pushState/replaceState for SPA navigation
      var origPush = history.pushState;
      var origReplace = history.replaceState;
      history.pushState = function() {
        var result = origPush.apply(this, arguments);
        setTimeout(runDOMPatches, 300);
        return result;
      };
      history.replaceState = function() {
        var result = origReplace.apply(this, arguments);
        setTimeout(runDOMPatches, 300);
        return result;
      };

      // Start
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', startObserving);
      } else {
        startObserving();
      }
    })();
    """
}
