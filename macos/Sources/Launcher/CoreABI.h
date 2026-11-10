// The contract between the launcher (Sources/Launcher) and the core it loads
// (Sources/IME and Sources/Shared, with the engine, built as a library).
//
// The launcher outlives every core it loads: an update replaces the core in
// the running process, and the launcher keeps serving the apps connected to
// it. So nothing here ever changes. A core that needs more from a launcher
// gets a new protocol and a new entry point, and keeps answering this one.
#import <AppKit/AppKit.h>
#import <InputMethodKit/InputMethodKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One per client text input: what its controller asks of the core loaded
/// now. IMK's calls, passed on as they come, on the main thread. (Named apart
/// from IMK's own methods, which IMK declares on every NSObject.)
@protocol OctoDotHandler <NSObject>
- (NSUInteger)eventMaskForClient:(nullable id)sender NS_SWIFT_NAME(eventMask(for:));
- (BOOL)handleKey:(nullable NSEvent *)event client:(nullable id)sender NS_SWIFT_NAME(handleKey(_:client:));
- (nullable NSMenu *)inputMenu NS_SWIFT_NAME(inputMenu());
/// An input menu item was chosen (IMK sends the item's action to the controller).
- (void)chooseMenuItem:(nullable id)sender NS_SWIFT_NAME(chooseMenuItem(_:));
- (void)commitCompositionForClient:(nullable id)sender NS_SWIFT_NAME(commitComposition(for:));
- (void)activateForClient:(nullable id)sender NS_SWIFT_NAME(activate(_:));
- (void)deactivateForClient:(nullable id)sender NS_SWIFT_NAME(deactivate(_:));
/// The core is about to be replaced or the process is terminating. A v2
/// launcher waits for composition to end before replacement.
- (void)retire;
@end

/// The core, as its entry point returns it:
///     void *octodot_core_v1(void);    // a retained object
@protocol OctoDotCore <NSObject>
/// Starts the engine and what runs with it. Returns the engine's status:
/// 0, or why the images did not load (then every key goes to the app).
- (int)start;
- (id<OctoDotHandler>)handlerForController:(IMKInputController *)controller NS_SWIFT_NAME(handler(for:));
/// Ends everything start began, before another core starts or the process
/// exits: learning saved, windows gone, the engine's memory released.
- (void)stop;
/// A maintenance command (--register, --selftest, ...): the exit status.
- (int)runCommand:(NSString *)command NS_SWIFT_NAME(run(command:));
@end

/// Added separately from v1 so older cores remain loadable. A generation is
/// started against its own retained copy of the data, including on rollback.
@protocol OctoDotCoreV2 <OctoDotCore>
- (int)startWithDataDirectory:(NSString *)directory NS_SWIFT_NAME(start(dataDirectory:));
/// False while a contained worker still prevents the runtime from stopping.
- (BOOL)readyForReload;
/// Stops only when it is safe to tear down the engine.
- (BOOL)stopForReload;
@end

@protocol OctoDotHandlerV2 <OctoDotHandler>
/// The launcher defers a switch rather than ending a user's composition.
- (BOOL)hasActiveComposition;
@end

NS_ASSUME_NONNULL_END
