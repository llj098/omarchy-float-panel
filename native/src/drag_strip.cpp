#include "drag_strip.hpp"
#include <algorithm>
#include <cmath>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <src/Compositor.hpp>
#include <src/desktop/state/ViewState.hpp>
#include <src/desktop/state/WindowState.hpp>
#include <src/desktop/view/Window.hpp>
#include <src/desktop/Workspace.hpp>
#include <src/event/EventBus.hpp>
#include <src/layout/LayoutManager.hpp>
#include <src/layout/supplementary/DragController.hpp>
#include <src/managers/input/InputManager.hpp>
#include <src/managers/SeatManager.hpp>
#include <src/managers/SessionLockManager.hpp>
#include <src/output/Monitor.hpp>
#include <src/pointer/cursor/CursorShapeOverrideController.hpp>
#include <src/plugins/PluginSystem.hpp>
#include <src/protocols/InputCapture.hpp>
#include <src/protocols/SessionLock.hpp>
#include <src/render/Renderer.hpp>
#include <src/render/decorations/IHyprWindowDecoration.hpp>
#include <src/render/pass/RectPassElement.hpp>
#include <src/state/MonitorState.hpp>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

namespace DragStrip {
namespace {
using Event = Event::CEventBus::CCustomEvent;
using Controller = Layout::Supplementary::CDragStateController;
HANDLE handle = nullptr;
bool running = false, resetting = false, starting = false, ending = false;
uint64_t serial = 0;
std::vector<SP<Event>> events;
std::vector<CHyprSignalListener> listeners;
std::vector<std::string> functions;
CFunctionHook *beginHook = nullptr, *endHook = nullptr, *boxHook = nullptr;
wl_event_source* idle = nullptr;
struct Primitive {
    PHLWINDOWREF window;
    IHyprWindowDecoration* deco = nullptr;
    double height = 6, inset = 0;
    uint32_t color = 0xff89b4fa;
    std::string cursor;
    bool visible = false;
    CBox lastBox;
};
using PrimitivePtr = std::shared_ptr<Primitive>;
std::unordered_map<std::string, PrimitivePtr> primitives;
PrimitivePtr hovered, offered, captured;
uint32_t offeredButton = 0;
// Both halves of these presses bypass core bookkeeping. Keep tombstones even
// after removal/reload: an unmatched release must never reach a client/core.
std::unordered_set<uint32_t> swallowed;
std::unordered_set<uint32_t> physicalButtons;
uint32_t lastPress = 0;
bool claimedPress = false;
bool cursorOwned = false;
struct Operation {
    PHLWINDOWREF window;
    std::string mode, sequence;
    uint32_t button = 0;
    bool bridge = false, begun = false, terminal = false, lossAnnounced = false;
};
std::shared_ptr<Operation> operation;
bool bridgeStarting = false;

std::string address(const PHLWINDOW& w) { return std::format("0x{:x}", reinterpret_cast<uintptr_t>(w.get())); }
PHLWINDOW resolve(const char* a) {
    if (!a) return nullptr;
    for (const auto& w : Desktop::windowState()->windows())
        if (w && address(w) == a) return w;
    return nullptr;
}
void emit(size_t n, const std::vector<Event::ValidVariant>& args) {
    if (running && !resetting && n < events.size()) { auto e = events[n]; (void)e->emit(args); }
}
void pointer(const PrimitivePtr& p, const std::string& phase, uint32_t button = 0) {
    if (p && p->window.lock()) emit(0, {p->window, phase, static_cast<int>(button)});
}
void terminal(std::shared_ptr<Operation> op, const std::string& phase) {
    if (!op || op->terminal) return;
    op->terminal = true;
    if (operation == op) operation.reset();
    if (op->window.lock()) emit(1, {op->window, phase, op->mode, op->sequence});
}
void clearCursor() {
    if (!cursorOwned) return;
    cursorOwned = false;
    Pointer::Cursor::overrideController->unsetOverride(Pointer::Cursor::CURSOR_OVERRIDE_UNKNOWN);
}
bool blocked() {
    return !g_pCompositor->m_sessionActive || g_pSessionLockManager->isSessionLocked() || PROTO::inputCapture->isCaptured() ||
        g_pSeatManager->m_seatGrab || g_pInputManager->isConstrained() ||
        g_pInputManager->getClickMode() != CLICKMODE_DEFAULT;
}
CBox primitiveBox(const PrimitivePtr& p) {
    const auto w = p->window.lock();
    if (!validMapped(w)) return {};
    auto b = w->getWindowMainSurfaceBox();
    const auto ws = w->m_workspace;
    if (ws && !w->m_pinned) b.translate(ws->m_renderOffset->value());
    b.translate(w->m_floatingOffset);
    b.y -= p->height;
    b.h = p->height;
    b.x += std::min(p->inset, b.w / 2);
    b.w = std::max(0.0, b.w - 2 * p->inset);
    return b;
}
using BoxFn = CBox (*)(CDecorationPositioner*, IHyprWindowDecoration*);
CBox decorationBox(CDecorationPositioner* self, IHyprWindowDecoration* deco) {
    // Core cursor/input routing must see the same logical rectangle as our hit
    // test and paint. Never modify the positioner's cached layout geometry.
    for (const auto& [_, p] : primitives)
        if (p->deco == deco) return primitiveBox(p);
    return reinterpret_cast<BoxFn>(boxHook->m_original)(self, deco);
}
void schedule();
class Decoration : public IHyprWindowDecoration {
    PrimitivePtr p;
  public:
    Decoration(PHLWINDOW w, PrimitivePtr state) : IHyprWindowDecoration(w), p(std::move(state)) { p->deco = this; }
    ~Decoration() override {
        p->deco = nullptr;
        if (handle) {
            if (auto plugin = g_pPluginSystem->getPluginByHandle(handle)) std::erase(plugin->m_registeredDecorations, this);
        }
        schedule();
    }
    SDecorationPositioningInfo getPositioningInfo() override {
        return {.policy = DECORATION_POSITION_STICKY, .edges = DECORATION_EDGE_TOP, .priority = 10000,
            .desiredExtents = {{0.0, p->height}, {}}, .reserved = false};
    }
    void onPositioningReply(const SDecorationPositioningReply&) override { schedule(); }
    void draw(PHLMONITOR monitor, float const& alpha) override {
        const auto b = primitiveBox(p);
        if (b != p->lastBox) { p->lastBox = b; schedule(); }
        if (!p->visible || b.w <= 0) return;
        auto box = b;
        box.translate(-monitor->m_position).scale(monitor->m_scale).round();
        auto color = CHyprColor(p->color);
        color.a *= alpha;
        CRectPassElement::SRectData data{};
        data.box = box; data.color = color;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(data));
    }
    eDecorationType getDecorationType() override { return DECORATION_CUSTOM; }
    eDecorationLayer getDecorationLayer() override { return DECORATION_LAYER_OVER; }
    uint64_t getDecorationFlags() override { return DECORATION_ALLOWS_MOUSE_INPUT | DECORATION_NON_SOLID; }
    std::string getDisplayName() override { return "float-panel drag strip"; }
    void updateWindow(PHLWINDOW) override { damageEntire(); schedule(); }
    void damageEntire() override { g_pHyprRenderer->damageBox(primitiveBox(p)); }
};

PrimitivePtr hit(const Vector2D& pos) {
    if (blocked() || g_layoutManager->dragController()->target() || g_pInputManager->getModsFromAllKBs()) return {};
    auto tester = Desktop::viewState()->hitTest();
    for (const auto& m : State::monitorState()->monitors()) {
        if (!CBox{m->m_position, m->m_size}.containsPoint(pos)) continue;
        Vector2D local; PHLLS layer;
        if (tester.layerPopupSurfaceAt(pos, m, &local, &layer)) return {};
        for (int i : {3, 2})
            if (tester.layerSurfaceAt(pos, &m->m_layerSurfaceLayers[i], &local, &layer)) return {};
    }
    auto w = tester.windowAt(pos, Desktop::View::ALLOW_FLOATING | Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS);
    if (!validMapped(w) || !w->visible() || w->hasPopupAt(pos)) return {};
    auto it = primitives.find(address(w));
    if (it == primitives.end() || !it->second->deco || it->second->window.lock() != w) return {};
    auto p = it->second;
    const auto b = primitiveBox(p);
    return b.w > 0 && b.containsPoint(pos) ? p : PrimitivePtr{};
}
void refresh() {
    if (!running || resetting) return;
    if (blocked()) {
        auto op = operation;
        if (op && !op->lossAnnounced) {
            op->lossAnnounced = true;
            emit(0, {op->window, std::string("lost"), 0});
        } else if (!op && captured) {
            auto old = captured;
            captured.reset();
            pointer(old, "lost");
        }
    }
    auto next = hit(g_pInputManager->getMouseCoordsInternal());
    if (next != hovered) {
        auto old = hovered;
        hovered = next;
        clearCursor();
        pointer(old, "leave");
        // A leave handler may synchronously destroy/reconfigure the next window.
        if (next && next->deco && hovered == next) pointer(next, "enter");
    }
    if (hovered && hovered->deco && !hovered->cursor.empty() && !blocked()) {
        cursorOwned = true;
        Pointer::Cursor::overrideController->setOverride(hovered->cursor, Pointer::Cursor::CURSOR_OVERRIDE_UNKNOWN);
    } else clearCursor();
}
void schedule() {
    if (!running || resetting || idle) return;
    idle = wl_event_loop_add_idle(g_pCompositor->m_wlEventLoop, [](void*) { idle = nullptr; refresh(); }, nullptr);
}

using BeginFn = void (*)(Controller*, SP<Layout::ITarget>, eMouseBindMode, std::optional<Layout::eRectCorner>, bool);
using EndFn = void (*)(Controller*);
void onBegin(Controller* self, SP<Layout::ITarget> target, eMouseBindMode mode, std::optional<Layout::eRectCorner> edge, bool exclusive) {
    const auto original = reinterpret_cast<BeginFn>(beginHook->m_original);
    if (starting || ending || !target) return; // no reentrant replacement of core's in-flight operation
    starting = true;
    if (operation) terminal(operation, "abort");
    auto w = target->window();
    if (!w) { original(self, target, mode, edge, exclusive); starting = false; return; }
    auto op = std::make_shared<Operation>();
    op->window = w; op->mode = mode == MBIND_MOVE ? "move" : "resize";
    op->sequence = std::to_string(++serial); op->bridge = bridgeStarting;
    op->button = physicalButtons.contains(lastPress) ? lastPress : 0;
    operation = op;
    emit(1, {op->window, std::string("begin"), op->mode, op->sequence});
    const auto stillClaimed = [&] { return !op->bridge || (captured && captured->deco && captured->window.lock() == w); };
    if (validMapped(w) && target->workspace() && stillClaimed()) original(self, target, mode, edge, exclusive);
    starting = false;
    if (!op->terminal && (self->target() != target || self->mode() == MBIND_INVALID || !validMapped(w) || !stillClaimed())) {
        terminal(op, "rejected");
        if (op->bridge && self->target() == target) g_layoutManager->endDragTarget();
    } else if (!op->terminal) op->begun = true;
    schedule();
}
void onEnd(Controller* self) {
    if (ending) return;
    auto op = operation;
    ending = true;
    // Core 0.56.2 assumes a non-null target. Nested rejected starts also end here.
    if (self->target()) reinterpret_cast<EndFn>(endHook->m_original)(self);
    ending = false;
    // A core end while the initiating button is still down is an interruption
    // (e.g. a floating-mode dispatcher), not the gesture's completed release.
    if (op) terminal(op, !op->begun ? "rejected" :
        op->button && !physicalButtons.contains(op->button) && validMapped(op->window.lock()) ? "end" : "abort");
    schedule();
}
void finishOwned(const PHLWINDOW& w) {
    auto op = operation;
    if (!op || !op->bridge || op->window.lock() != w || starting || ending) return;
    const auto& c = g_layoutManager->dragController();
    if (c->target() && c->target()->window() == w) g_layoutManager->endDragTarget();
    else terminal(op, "abort");
}
void remove(const PrimitivePtr& p) {
    const auto w = p->window.lock();
    if (captured == p) { captured.reset(); pointer(p, "lost"); }
    if (hovered == p) { hovered.reset(); clearCursor(); pointer(p, "leave"); }
    finishOwned(w);
    if (p->deco && w) {
        auto d = p->deco;
        d->damageEntire();
        p->deco = nullptr;
        HyprlandAPI::removeWindowDecoration(handle, d);
        // 0.56.2 queues removal but updateWindowDecos returns early for hidden /
        // unmapped windows. Drain only our own resource while its vtable is live.
        std::erase(w->m_decosToRemove, d);
        for (const auto& item : w->m_windowDecorations)
            if (item.get() == d) g_pDecorationPositioner->uncacheDecoration(d);
        std::erase_if(w->m_windowDecorations, [d](const auto& item) { return item.get() == d; });
        // The SDK remove call also leaves its registration list untouched.
        // Do not let later unload mistake a recycled pointer for our decoration.
        if (auto plugin = g_pPluginSystem->getPluginByHandle(handle)) std::erase(plugin->m_registeredDecorations, d);
    }
    schedule();
}
int result(lua_State* L, bool v) { lua_pushboolean(L, v); return 1; }
PrimitivePtr argument(lua_State* L) {
    const char* a = lua_tostring(L, 1);
    auto w = resolve(a);
    if (!w) return {};
    auto it = primitives.find(a);
    return it != primitives.end() && it->second->window.lock() == w ? it->second : PrimitivePtr{};
}
double number(lua_State* L, const char* key, double fallback) {
    lua_getfield(L, 2, key); const double v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : fallback; lua_pop(L, 1); return v;
}
int set(lua_State* L) {
    auto w = resolve(lua_tostring(L, 1));
    if (resetting || !validMapped(w) || !lua_istable(L, 2)) return result(L, false);
    const double height = number(L, "height", 6), inset = number(L, "hit_inset", 0);
    const double color = number(L, "color", 0xff89b4fa);
    if (!std::isfinite(height) || height < 1 || height > 64 || !std::isfinite(inset) || inset < 0 ||
        !std::isfinite(color) || color < 0 || color > 4294967295.0) return result(L, false);
    auto key = address(w);
    auto p = argument(L);
    if (!p) { p = std::make_shared<Primitive>(); p->window = w; primitives[key] = p; }
    if (p->deco) p->deco->damageEntire();
    const bool dimensions = p->height != height || p->inset != inset;
    p->height = height; p->inset = inset;
    p->color = static_cast<uint32_t>(color);
    lua_getfield(L, 2, "visible"); p->visible = lua_toboolean(L, -1); lua_pop(L, 1);
    lua_getfield(L, 2, "cursor"); p->cursor = lua_isstring(L, -1) ? lua_tostring(L, -1) : ""; lua_pop(L, 1);
    if (!p->deco && !HyprlandAPI::addWindowDecoration(handle, w, makeUnique<Decoration>(w, p))) { primitives.erase(key); return result(L, false); }
    if (dimensions && p->deco) g_pDecorationPositioner->repositionDeco(p->deco);
    if (!p->deco) return result(L, false);
    p->deco->damageEntire(); schedule();
    return result(L, true);
}
int erase(lua_State* L) {
    auto p = argument(L);
    if (p) { primitives.erase(address(p->window.lock())); remove(p); }
    return result(L, true);
}
int capture(lua_State* L) {
    auto p = argument(L);
    const auto button = static_cast<uint32_t>(lua_tointeger(L, 2));
    if (!p || p != offered || button != offeredButton || captured || claimedPress) return result(L, false);
    captured = p; claimedPress = true; swallowed.insert(button);
    return result(L, true);
}
int release(lua_State* L) {
    auto p = argument(L);
    if (p && captured == p) captured.reset();
    return result(L, true);
}
int begin(lua_State* L) {
    auto p = argument(L);
    const char* mode = lua_tostring(L, 2);
    auto w = p ? p->window.lock() : nullptr;
    if (!p || p != captured || !validMapped(w) || !w->layoutTarget() || !w->layoutTarget()->workspace() ||
        !mode || std::string_view(mode) != "move" || blocked() || starting || ending || g_layoutManager->dragController()->target()) return result(L, false);
    bridgeStarting = true;
    g_layoutManager->beginDragTarget(w->layoutTarget(), MBIND_MOVE, std::nullopt, true);
    bridgeStarting = false;
    return result(L, operation && operation->bridge && operation->begun && operation->window.lock() == w);
}
int finish(lua_State* L) { auto p = argument(L); if (p) finishOwned(p->window.lock()); return result(L, true); }
void button(IPointer::SButtonEvent e, ::Event::SCallbackInfo& info) {
    if (e.state == WL_POINTER_BUTTON_STATE_PRESSED) { lastPress = e.button; physicalButtons.insert(e.button); }
    else physicalButtons.erase(e.button);
    if (e.state == WL_POINTER_BUTTON_STATE_RELEASED && swallowed.erase(e.button)) {
        info.cancelled = true;
        auto p = captured;
        pointer(p, "release", e.button);
        if (captured == p) captured.reset();
        if (p) finishOwned(p->window.lock());
        schedule(); return;
    }
    if (info.cancelled || resetting || e.state != WL_POINTER_BUTTON_STATE_PRESSED || !swallowed.empty() ||
        g_pInputManager->hasHeldButtons()) return;
    auto p = hit(g_pInputManager->getMouseCoordsInternal());
    if (!p) return;
    offered = p; offeredButton = e.button; claimedPress = false;
    pointer(p, "press", e.button);
    offered.reset(); offeredButton = 0;
    if (claimedPress) info.cancelled = true;
    schedule();
}
void installHook(CFunctionHook*& out, const std::string& name, const void* callback) {
    auto matches = HyprlandAPI::findFunctionsByName(handle, name.substr(name.rfind("::") + 2));
    std::erase_if(matches, [&](const auto& match) { return match.demangled.find(name + "(") == std::string::npos; });
    if (matches.size() != 1) throw std::runtime_error("float-panel: ambiguous/missing native symbol " + name);
    out = HyprlandAPI::createFunctionHook(handle, matches[0].address, callback);
    if (!out || !out->hook()) throw std::runtime_error("float-panel: cannot hook " + name);
}
} // namespace

bool ready() { return running; }
void announce(bool added) {
    for (const auto& e : events) {
        if (added) ::Event::bus()->m_events.pluginEventAdded.emit(e);
        else ::Event::bus()->m_events.pluginEventRemoved.emit(e->m_name);
    }
}
void reset() {
    auto op = operation;
    terminal(op, "abort"); // notify the old Lua state before detaching its events
    resetting = true;
    if (idle) { wl_event_source_remove(idle); idle = nullptr; }
    // Finish only the bridge's target; a capture may already have been released.
    if (op && op->bridge) {
        const auto& c = g_layoutManager->dragController();
        if (c->target() && c->target()->window() == op->window.lock()) g_layoutManager->endDragTarget();
    }
    auto old = std::move(primitives); primitives.clear();
    for (const auto& [_, p] : old) remove(p);
    hovered.reset(); captured.reset(); offered.reset(); clearCursor();
    resetting = false;
}
void stop() {
    reset(); running = false;
    listeners.clear();
    for (auto* h : {boxHook, endHook, beginHook}) if (h) HyprlandAPI::removeFunctionHook(handle, h);
    boxHook = endHook = beginHook = nullptr;
    for (const auto& name : functions) HyprlandAPI::removeLuaFunction(handle, "float_panel", name);
    functions.clear();
    for (const auto& e : events) HyprlandAPI::removeEvent(handle, e->m_name);
    events.clear(); swallowed.clear(); physicalButtons.clear(); lastPress = 0; handle = nullptr;
}
void init(HANDLE h) {
    handle = h;
    try {
        for (auto [name, fn] : std::vector<std::pair<std::string, lua_CFunction>>{
            {"decoration_set", set}, {"decoration_remove", erase}, {"decoration_capture", capture},
            {"decoration_release", release}, {"drag_begin", begin}, {"drag_finish", finish}}) {
            if (!HyprlandAPI::addLuaFunction(handle, "float_panel", name, fn)) throw std::runtime_error("float-panel: cannot register " + name);
            functions.push_back(name);
        }
        for (auto [name, types] : std::vector<std::pair<std::string, std::vector<Event::eType>>>{
            {"float_panel.decoration_pointer", {Event::TYPE_WINDOW, Event::TYPE_STRING, Event::TYPE_INT}},
            {"float_panel.drag", {Event::TYPE_WINDOW, Event::TYPE_STRING, Event::TYPE_STRING, Event::TYPE_STRING}},
            {"float_panel.window_changed", {Event::TYPE_WINDOW}}}) {
            auto e = makeShared<Event>(name, types);
            if (!HyprlandAPI::addEvent(handle, e)) throw std::runtime_error("float-panel: cannot register " + name);
            events.push_back(e);
        }
        installHook(beginHook, "CDragStateController::dragBegin", reinterpret_cast<void*>(onBegin));
        installHook(endHook, "CDragStateController::dragEnd", reinterpret_cast<void*>(onEnd));
        installHook(boxHook, "CDecorationPositioner::getWindowDecorationBox", reinterpret_cast<void*>(decorationBox));
        running = true;
        auto& bus = ::Event::bus()->m_events;
        listeners.push_back(bus.input.mouse.move.listen([](Vector2D, ::Event::SCallbackInfo&) { schedule(); }));
        listeners.push_back(bus.input.mouse.button.listen(button));
        listeners.push_back(bus.window.floating.listen([](PHLWINDOW w) { emit(2, {PHLWINDOWREF(w)}); schedule(); }));
        listeners.push_back(bus.window.close.listen([](PHLWINDOW w) {
            auto op = operation;
            if (op && op->window.lock() == w) {
                terminal(op, "abort");
                const auto& c = g_layoutManager->dragController();
                if (op->bridge && c->target() && c->target()->window() == w) g_layoutManager->endDragTarget();
            }
            auto it = primitives.find(address(w));
            if (it != primitives.end()) { auto p = it->second; primitives.erase(it); remove(p); }
            schedule();
        }));
        listeners.push_back(bus.window.active.listen([](auto, auto) { schedule(); }));
        listeners.push_back(bus.window.open.listen([](auto) { schedule(); }));
        listeners.push_back(bus.window.openLate.listen([](PHLWINDOW w) { emit(2, {PHLWINDOWREF(w)}); schedule(); }));
        listeners.push_back(bus.window.updateRules.listen([](PHLWINDOW w) { emit(2, {PHLWINDOWREF(w)}); schedule(); }));
        listeners.push_back(bus.window.fullscreen.listen([](auto) { schedule(); }));
        listeners.push_back(bus.window.moveToWorkspace.listen([](auto, auto) { schedule(); }));
        listeners.push_back(bus.workspace.active.listen([](auto) { schedule(); }));
        listeners.push_back(bus.workspace.specialActive.listen([](auto, auto) { schedule(); }));
        listeners.push_back(bus.layer.opened.listen([](auto) { schedule(); }));
        listeners.push_back(bus.layer.closed.listen([](auto) { schedule(); }));
        listeners.push_back(bus.monitor.layoutChanged.listen([] { schedule(); }));
        listeners.push_back(g_pSeatManager->m_events.pointerFocusChange.listen([] { schedule(); }));
        listeners.push_back(PROTO::sessionLock->m_events.newLock.listen([](auto) {
            auto op = operation;
            if (op) { op->lossAnnounced = true; emit(0, {op->window, std::string("lost"), 0}); }
            else { auto p = captured; pointer(p, "lost"); }
            clearCursor(); schedule();
        }));
    } catch (...) { stop(); throw; }
}
} // namespace DragStrip
