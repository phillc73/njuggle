const std = @import("std");

const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const n = @import("../build/info.zig");
const i18n = @import("../../../os/main.zig").i18n;
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const SidebarPaneRow = @import("sidebar_pane_row.zig").SidebarPaneRow;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const Window = @import("window.zig").Window;
const status_icon = @import("status_icon.zig");
const tab_status = @import("tab_status.zig");
const sidebar_status = @import("sidebar_status.zig");

/// The states in texture-list order, and the repaint logic that maps a state
/// to an index. Both live in `sidebar_status.zig`, which is GTK-free so the
/// mapping is tested; this file supplies the widgets.
const status_states = sidebar_status.status_states;

const log = std.log.scoped(.gtk_ghostty_sidebar_row);

/// One row of the tab sidebar.
///
/// This exists as its own widget for a specific reason. A
/// `GtkBuilderListItemFactory` template cannot connect a signal to a Zig
/// handler, so a close button inside the factory template has no way to act.
/// Binding the action target to `GtkListItem:position` looks like it works —
/// it even compiles — but GObject has no guint-to-GVariant transform, and it
/// fails at runtime with:
///
///     Unable to convert a value of type guint to a value of type GVariant
///
/// A row that *owns its page* needs neither a position nor a variant. It is
/// also the ordinary GTK4 way to do this.
pub const SidebarRow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySidebarRow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const page = struct {
            pub const name = "page";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*adw.TabPage,
                .{
                    .accessor = C.privateObjFieldAccessor("page"),
                },
            );
        };
    };

    /// One followed pane: the surface whose "status" notify we watch, and the
    /// handler id to cut. Declared outside `Private` because Zig does not
    /// allow declarations between container fields.
    const StatusWatch = struct {
        surface: *Surface,
        handler: c_ulong,
    };

    const Private = struct {
        /// The tab this row stands for. Borrowed from the tab view.
        page: ?*adw.TabPage = null,

        /// Right-click menu. The horizontal tab bar carries one of these
        /// upstream; hiding that bar took it away, so the sidebar restores it.
        menu: *gtk.PopoverMenu,

        /// Starts a drag carrying this row's page. The content is built
        /// lazily in `dragPrepare`, not stored here, because rows are
        /// recycled -- the page a drag started on must be read at drag
        /// time, same reasoning as `livePage`.
        drag_source: *gtk.DragSource,

        /// Accepts a page dropped on this row and reorders the tab view to
        /// match. Its accepted GType is restricted to `AdwTabPage` in
        /// `init`, since blueprint has no syntax for a GType list.
        drop_target: *gtk.DropTarget,

        /// Actions the menu items target, scoped to this row under "row".
        action_group: ?*gio.SimpleActionGroup = null,

        /// Second-level pane rows, one per leaf in the tab's split tree.
        panes_box: *gtk.Box,

        /// The per-tab status indicator, left of the close button. Fed from
        /// the leaf surfaces' "status" property (tab_status.zig holds the
        /// rules); one image, repainted when the aggregate changes.
        status_image: *gtk.Image,

        /// The three state images, decoded once for the application rather
        /// than once per row: rows are recycled on every scroll.
        status_textures: ?[status_states.len]*gdk.Texture = null,

        /// The state currently shown, so notifies from several panes cost one
        /// repaint per real change rather than one per signal.
        status_shown: tab_status.State = .idle,

        /// Each leaf surface whose "status" we follow, disconnected when the
        /// row rebinds or the split tree changes.
        status_watches: std.ArrayListUnmanaged(StatusWatch) = .empty,

        /// The split tree we're currently listening to, borrowed from the
        /// bound tab. Rows are recycled, so this must be disconnected
        /// before rebinding to a different page's tree, same reasoning as
        /// `Sidebar.selected_page_handler` in sidebar.zig: zig-gobject's
        /// connect doesn't tie the handler's life to ours.
        split_tree: ?*SplitTree = null,
        split_tree_changed_handler: c_ulong = 0,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        self.initActionMap();

        // Reject anything that isn't a tab page -- there is no other kind
        // of drag this row should ever accept.
        var drop_target_types = [_]gobject.Type{adw.TabPage.getGObjectType()};
        self.private().drop_target.setGtypes(&drop_target_types, drop_target_types.len);

        // Rows are recycled: when the factory rebinds this row to another
        // tab, the dot must follow the new tab, not keep the old one's colour.
        _ = gobject.Object.signals.notify.connect(
            self,
            *Self,
            notifyPage,
            self,
            .{ .detail = "page" },
        );

        self.loadStatusTextures();
        self.syncStatus();
    }
    /// The row's subtitle: the last segment of the working directory.
    ///
    /// The full path is what `pwd` carries, and it is far too long for a
    /// sidebar column — `~/Github/prokai-plugins` ellipsizes to noise. The
    /// last segment is what actually distinguishes one tab from another.
    fn closureCwd(
        _: *Self,
        pwd_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const pwd = pwd_ orelse return null;
        const span = std.mem.span(pwd);
        if (span.len == 0) return null;

        // MUST allocate. Three independent reviewers said this dupeZ leaks —
        // that GTK copies the returned string and never frees it. It was tried
        // their way and the binary aborted on exit with
        // `munmap_chunk(): invalid pointer`, in every mode: something DOES
        // free this pointer, so returning an interior pointer into the
        // caller's buffer hands free() an address it never allocated.
        // Unanimous review lost to one run of the program.
        const base = std.fs.path.basename(span);
        return glib.ext.dupeZ(u8, if (base.len == 0) span else base);
    }

    fn notifyPage(_: *Self, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.reconnectSplitTree();
    }

    /// Follow the bound tab's split tree, so panes rebuild live off its
    /// `changed` signal instead of being polled.
    fn reconnectSplitTree(self: *Self) void {
        const priv = self.private();

        if (priv.split_tree) |st| {
            if (priv.split_tree_changed_handler != 0) {
                gobject.signalHandlerDisconnect(
                    st.as(gobject.Object),
                    priv.split_tree_changed_handler,
                );
                priv.split_tree_changed_handler = 0;
            }
            priv.split_tree = null;
        }

        const st: ?*SplitTree = st: {
            const page = priv.page orelse break :st null;
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse break :st null;
            break :st tab.getSplitTree();
        };

        const tree: ?*Surface.Tree = tree: {
            const s = st orelse break :tree null;
            priv.split_tree = s;
            priv.split_tree_changed_handler = SplitTree.signals.changed.connect(
                s,
                *Self,
                splitTreeChanged,
                self,
                .{},
            );
            break :tree s.getTree();
        };

        self.syncPanes(tree);
        self.reconnectStatusWatches(tree);
        self.syncStatus();
    }

    /// Decode the three state images once, from the embedded gresource. A
    /// missing or undecodable asset leaves the list null, which the repaint
    /// reads as "hide the indicator" rather than a crash on a bad build.
    fn loadStatusTextures(self: *Self) void {
        const priv = self.private();
        if (priv.status_textures != null) return;

        var loaded: [status_states.len]*gdk.Texture = undefined;
        var count: usize = 0;
        for (status_states) |state| {
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(
                &path_buf,
                "{s}/status/{s}.png",
                .{ n.resource_path, tab_status.assetColour(state) },
                0,
            ) catch {
                log.warn("status icon path too long", .{});
                for (loaded[0..count]) |t| t.unref();
                return;
            };
            loaded[count] = loadResourceTexture(path) orelse {
                log.warn("status icon missing at {s}", .{path});
                for (loaded[0..count]) |t| t.unref();
                return;
            };
            count += 1;
        }
        priv.status_textures = loaded;
    }

    fn loadResourceTexture(path: [:0]const u8) ?*gdk.Texture {
        const bytes = gio.resourcesLookupData(path, .{}, null) orelse return null;
        defer bytes.unref();
        return gdk.Texture.newFromBytes(bytes, null);
    }

    /// Follow each leaf surface's "status" so a command starting or finishing
    /// in any pane repaints this row at once. Same lifecycle rule as the
    /// split tree above: the handlers outlive a recycled row unless cut.
    fn reconnectStatusWatches(self: *Self, tree: ?*const Surface.Tree) void {
        const priv = self.private();

        for (priv.status_watches.items) |watch| {
            gobject.signalHandlerDisconnect(watch.surface.as(gobject.Object), watch.handler);
        }
        priv.status_watches.clearRetainingCapacity();

        const t = tree orelse return;
        var it = t.iterator();
        while (it.next()) |entry| {
            const handler = gobject.Object.signals.notify.connect(
                entry.view,
                *Self,
                surfaceStatusChanged,
                self,
                .{ .detail = "status" },
            );
            priv.status_watches.append(Application.default().allocator(), .{
                .surface = entry.view,
                .handler = handler,
            }) catch {
                gobject.signalHandlerDisconnect(entry.view.as(gobject.Object), handler);
                log.warn("out of memory watching pane status", .{});
                return;
            };
        }
    }

    fn surfaceStatusChanged(_: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.syncStatus();
    }

    /// Repaint the indicator from the current state of every pane in the tab.
    /// Red outranks green outranks grey, which `aggregate` owns.
    fn syncStatus(self: *Self) void {
        const priv = self.private();

        const state: tab_status.State = state: {
            const st = priv.split_tree orelse break :state .idle;
            const t = st.getTree() orelse break :state .idle;
            var it = t.iterator();
            var buf: [16]tab_status.State = undefined;
            var len: usize = 0;
            while (it.next()) |entry| {
                if (len == buf.len) break;
                buf[len] = entry.view.getStatus();
                len += 1;
            }
            break :state tab_status.aggregate(buf[0..len]);
        };

        // The paint itself is `sidebar_status.zig`'s, which is GTK-free and
        // therefore tested: the state-to-texture mapping, the hide-when-off
        // path and the unchanged-state shortcut all have their tests there.
        // This file only hands over the widget, the flag and the textures.
        var icons: ?sidebar_status.StatusIcons = null;
        if (priv.status_textures) |t| {
            var handles: [status_states.len]*anyopaque = undefined;
            for (t, 0..) |texture, i| handles[i] = @ptrCast(texture);
            icons = .{ .images = handles };
        }
        var kit: sidebar_status.Kit(sidebar_status.Gtk) = .{
            .image = priv.status_image,
            .enabled = self.statusIndicatorEnabled(),
            .icons = if (icons) |*i| i else null,
            .shown = priv.status_shown,
        };
        _ = kit.sync(&.{state});
        priv.status_shown = kit.shown;
    }

    /// The config key both hides the indicator and stops the repaint, so a
    /// user who turns it off pays nothing per command.
    fn statusIndicatorEnabled(self: *Self) bool {
        const page = self.livePage() orelse return false;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return false;
        return tab.getConfig().get().@"gtk-sidebar-status-icon";
    }

    fn splitTreeChanged(
        _: *SplitTree,
        _: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        self.syncPanes(new_tree);
        self.reconnectStatusWatches(new_tree);
        self.syncStatus();
    }

    /// Rebuild the second-level pane rows from the tree. A non-split tab
    /// (root is a leaf, or the tree is empty/null) leaves `panes_box`
    /// empty -- an empty GtkBox contributes no height, which is what keeps
    /// an unsplit tab's row pixel-identical to before this existed.
    fn syncPanes(self: *Self, tree: ?*const Surface.Tree) void {
        const priv = self.private();
        const box = priv.panes_box;

        var child_ = box.as(gtk.Widget).getFirstChild();
        while (child_) |child| {
            const next = child.getNextSibling();
            box.remove(child);
            child_ = next;
        }

        const t = tree orelse return;
        if (t.isEmpty()) return;
        if (t.nodes[0] == .leaf) return;

        var it = t.iterator();
        while (it.next()) |entry| {
            const row = gobject.ext.newInstance(SidebarPaneRow, .{ .surface = entry.view });
            _ = SidebarPaneRow.signals.activated.connect(
                row,
                *Self,
                paneActivated,
                self,
                .{},
            );
            box.append(row.as(gtk.Widget));
        }
    }

    fn paneActivated(row: *SidebarPaneRow, self: *Self) callconv(.c) void {
        const surface = row.getSurface() orelse return;

        // Same shape as Sidebar.rowActivated: select the tab this pane
        // belongs to before grabbing focus, so the surface is actually
        // visible when it becomes SplitTree.active-surface.
        const page = self.livePage() orelse return;
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return;
        window.getTabView().setSelectedPage(page);
        surface.grabFocus();
    }

    fn initActionMap(self: *Self) void {
        const actions = [_]ext.actions.Action(Self){
            .init("rename", actionRename, null),
            .init("close", actionClose, null),
        };
        self.private().action_group =
            ext.actions.addAsGroup(Self, self, "row", &actions);
    }

    /// Open the menu where the pointer is.
    fn rightClick(
        _: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // @intFromFloat is illegal behaviour on NaN, infinity, or anything
        // outside c_int. Gesture coordinates are finite in practice, but
        // "in practice" is not a guarantee the language makes.
        const safe = struct {
            fn coord(v: f64) c_int {
                if (!std.math.isFinite(v)) return 0;
                return @intFromFloat(std.math.clamp(v, 0, 100_000));
            }
        };
        const rect: gdk.Rectangle = .{
            .f_x = safe.coord(x),
            .f_y = safe.coord(y),
            .f_width = 1,
            .f_height = 1,
        };
        priv.menu.as(gtk.Popover).setPointingTo(&rect);
        priv.menu.as(gtk.Popover).popup();
    }

    /// Rename this row's tab, without switching to it. `Tab.promptTabTitle`
    /// is public, so the row does not have to select the page first and then
    /// route through a window action.
    fn actionRename(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const page = self.livePage() orelse return;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
        tab.promptTabTitle();
    }

    /// This row's page, but only if the tab view still holds it.
    ///
    /// Rows are recycled and a menu can stay open across a tab closing, so
    /// `priv.page` alone is not proof the page is alive. Acting on a departed
    /// page means either closing the wrong tab or dereferencing a child widget
    /// that has already been destroyed.
    fn livePage(self: *Self) ?*adw.TabPage {
        const priv = self.private();
        const page = priv.page orelse return null;
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return null;
        if (window.getTabView().getPagePosition(page) < 0) return null;
        return page;
    }

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.closeTab();
    }

    /// Close this row's tab.
    ///
    /// The tab view is reached by walking up to the window rather than being
    /// injected: a factory template can pass the row its item, but nothing
    /// else from the outer scope.
    fn closeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.closeTab();
    }

    /// Build the drag content when a drag actually starts on this row.
    /// Read at drag time rather than kept on `priv`, for the same
    /// recycling reason `livePage` exists: nothing guarantees the page
    /// this row showed when the drag gesture first touched down is still
    /// the one it shows once the drag threshold is crossed.
    fn dragPrepare(
        _: *gtk.DragSource,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) ?*gdk.ContentProvider {
        const page = self.livePage() orelse return null;

        var value = std.mem.zeroes(gobject.Value);
        _ = value.init(adw.TabPage.getGObjectType());
        defer value.unset();
        value.setObject(page.as(gobject.Object));

        return gdk.ContentProvider.newForValue(&value);
    }

    /// A tab page was dropped on this row: move it to this row's position
    /// in the tab view. This reuses `AdwTabView.reorderPage` -- the exact
    /// primitive `Window.moveTab` already ends with -- rather than
    /// reimplementing reordering; the sidebar's grouped/sorted model
    /// (`sortCompare` in sidebar.zig) picks the new order up on its own
    /// because it tiebreaks equal-group pages by tab-view position.
    fn rowDrop(
        _: *gtk.DropTarget,
        value: *gobject.Value,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        if (!ext.gValueHolds(value, adw.TabPage.getGObjectType())) return 0;
        const obj = value.getObject() orelse return 0;
        const source_page = gobject.ext.cast(adw.TabPage, obj) orelse return 0;

        const target_page = self.livePage() orelse return 0;
        if (source_page == target_page) return 0;

        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return 0;
        const tab_view = window.getTabView();

        // The source page must also still be live in this same tab view --
        // a page from a different window's sidebar has no position here.
        const desired_pos = tab_view.getPagePosition(source_page);
        if (desired_pos < 0) return 0;
        const target_pos = tab_view.getPagePosition(target_page);
        if (target_pos < 0) return 0;

        return @intFromBool(tab_view.reorderPage(source_page, target_pos) != 0);
    }

    fn closeTab(self: *Self) void {
        const page = self.livePage() orelse return;
        const window = ext.getAncestor(
            Window,
            self.as(gtk.Widget),
        ) orelse return;
        window.getTabView().closePage(page);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        for (priv.status_watches.items) |watch| {
            gobject.signalHandlerDisconnect(watch.surface.as(gobject.Object), watch.handler);
        }
        priv.status_watches.deinit(Application.default().allocator());
        if (priv.status_textures) |t| {
            for (t) |texture| texture.unref();
            priv.status_textures = null;
        }
        if (priv.split_tree) |st| {
            if (priv.split_tree_changed_handler != 0) {
                gobject.signalHandlerDisconnect(
                    st.as(gobject.Object),
                    priv.split_tree_changed_handler,
                );
                priv.split_tree_changed_handler = 0;
            }
            priv.split_tree = null;
        }
        priv.page = null;
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 4,
                    .name = "sidebar-row",
                }),
            );

            gobject.ext.ensureType(SidebarPaneRow);

            class.bindTemplateChildPrivate("menu", .{});
            class.bindTemplateChildPrivate("status_image", .{});
            class.bindTemplateChildPrivate("panes_box", .{});
            class.bindTemplateChildPrivate("drag_source", .{});
            class.bindTemplateChildPrivate("drop_target", .{});
            class.bindTemplateCallback("close_clicked", &closeClicked);
            class.bindTemplateCallback("right_click", &rightClick);
            class.bindTemplateCallback("computed_cwd", &closureCwd);
            class.bindTemplateCallback("drag_prepare", &dragPrepare);
            class.bindTemplateCallback("row_drop", &rowDrop);

            gobject.ext.registerProperties(class, &.{
                properties.page.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
