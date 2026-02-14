/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>
#include <QuartzCore/CAMetalLayer.h>
#include <stdatomic.h>

#include "common.h"
#include "context.h"
#include "utils.h"

struct priv {
    struct mpvk_ctx vk;
    CAMetalLayer *layer;
    void *observer;
    atomic_bool resize_pending;
    int last_w;
    int last_h;
};

@interface MoltenVKLayerObserver : NSObject
@property(nonatomic, assign) struct vo *vo;
@property(nonatomic, assign) atomic_bool *resizePending;
@property(nonatomic, assign) CAMetalLayer *layer;
- (void)start;
- (void)stop;
@end

@implementation MoltenVKLayerObserver

static void *kMoltenVKObserverContext = &kMoltenVKObserverContext;

- (void)start
{
    if (!self.layer)
        return;

    [self.layer addObserver:self
                 forKeyPath:@"bounds"
                    options:NSKeyValueObservingOptionNew
                    context:kMoltenVKObserverContext];
    [self.layer addObserver:self
                 forKeyPath:@"contentsScale"
                    options:NSKeyValueObservingOptionNew
                    context:kMoltenVKObserverContext];
}

- (void)stop
{
    if (!self.layer)
        return;

    @try {
        [self.layer removeObserver:self forKeyPath:@"bounds" context:kMoltenVKObserverContext];
        [self.layer removeObserver:self forKeyPath:@"contentsScale" context:kMoltenVKObserverContext];
    } @catch (__unused NSException *e) {
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context
{
    if (context != kMoltenVKObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    if (self.resizePending)
        atomic_store(self.resizePending, true);
    if (self.vo)
        vo_wakeup(self.vo);
}

@end

static bool get_layer_size(CAMetalLayer *layer, int *w, int *h)
{
    if (!layer)
        return false;

    CGSize bounds = layer.bounds.size;
    CGFloat scale = layer.contentsScale;
    int bw = (int)(bounds.width * scale);
    int bh = (int)(bounds.height * scale);
    if (bw > 1 && bh > 1) {
        *w = bw;
        *h = bh;
        return true;
    }

    CGSize s = layer.drawableSize;
    int dw = (int)s.width;
    int dh = (int)s.height;
    if (dw > 1 && dh > 1) {
        *w = dw;
        *h = dh;
        return true;
    }

    return false;
}

static bool get_effective_layer_size(struct priv *p, int *w, int *h)
{
    int cw = 0;
    int ch = 0;
    if (get_layer_size(p->layer, &cw, &ch)) {
        p->last_w = cw;
        p->last_h = ch;
        *w = cw;
        *h = ch;
        return true;
    }

    if (p->last_w > 1 && p->last_h > 1) {
        *w = p->last_w;
        *h = p->last_h;
        return true;
    }

    return false;
}

static void moltenvk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;

    if (p->observer) {
        MoltenVKLayerObserver *observer = p->observer;
        [observer stop];
        [observer release];
        p->observer = NULL;
    }

    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
    if (p->layer) {
        CFRelease((__bridge CFTypeRef)p->layer);
        p->layer = nil;
    }
}

static bool moltenvk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;
    atomic_store(&p->resize_pending, true);
    p->last_w = 0;
    p->last_h = 0;

    if (ctx->vo->opts->WinID == -1) {
        MP_MSG(ctx, msgl, "WinID missing\n");
        goto fail;
    }

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto fail;

    p->layer = (__bridge CAMetalLayer *)(intptr_t)ctx->vo->opts->WinID;
    CFRetain((__bridge CFTypeRef)p->layer);

    MoltenVKLayerObserver *observer = [MoltenVKLayerObserver new];
    observer.vo = ctx->vo;
    observer.resizePending = &p->resize_pending;
    observer.layer = p->layer;
    [observer start];
    p->observer = observer;

    VkMetalSurfaceCreateInfoEXT info = {
         .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
         .pLayer = p->layer,
    };

    struct ra_ctx_params params = {0};

    VkInstance inst = vk->vkinst->instance;
    VkResult res = vkCreateMetalSurfaceEXT(inst, &info, NULL, &vk->surface);
    if (res != VK_SUCCESS) {
        MP_MSG(ctx, msgl, "Failed creating MoltenVK surface\n");
        goto fail;
    }

    if (!ra_vk_ctx_init(ctx, vk, params, VK_PRESENT_MODE_FIFO_KHR))
        goto fail;

    return true;
fail:
    moltenvk_uninit(ctx);
    return false;
}

static bool moltenvk_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    int w = 0;
    int h = 0;
    atomic_store(&p->resize_pending, true);
    if (get_effective_layer_size(p, &w, &h))
        ra_vk_ctx_resize(ctx, w, h);
    return true;
}

static void moltenvk_wait_events(struct ra_ctx *ctx, int64_t until_time_ns)
{
    int64_t now = mp_time_ns();
    int64_t max_sleep_until = now + MP_TIME_MS_TO_NS(16);

    if (until_time_ns <= now || until_time_ns > max_sleep_until)
        until_time_ns = max_sleep_until;

    vo_wait_default(ctx->vo, until_time_ns);
}

static int moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    if (request == VOCTRL_CHECK_EVENTS) {
        struct priv *p = ctx->priv;
        int w = 0;
        int h = 0;
        bool resize_pending = atomic_exchange(&p->resize_pending, false);
        bool have_size = get_effective_layer_size(p, &w, &h);

        if (have_size && (w != ctx->vo->dwidth || h != ctx->vo->dheight)) {
            if (!ra_vk_ctx_resize(ctx, w, h))
                return VO_ERROR;
            *events |= VO_EVENT_RESIZE | VO_EVENT_EXPOSE;
        } else if (resize_pending) {
            *events |= VO_EVENT_EXPOSE;
        }
    }
    return VO_NOTIMPL;
}

const struct ra_ctx_fns ra_ctx_vulkan_moltenvk = {
    .type           = "vulkan",
    .name           = "moltenvk",
    .reconfig       = moltenvk_reconfig,
    .control        = moltenvk_control,
    .wait_events    = moltenvk_wait_events,
    .init           = moltenvk_init,
    .uninit         = moltenvk_uninit,
};
