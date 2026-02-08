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
#include <QuartzCore/CAMetalLayer.h>
#include <MoltenVK/mvk_vulkan.h>

#include "common.h"
#include "context.h"
#include "utils.h"

struct priv {
    struct mpvk_ctx vk;
    CAMetalLayer *layer;
};

static bool get_layer_size(CAMetalLayer *layer, int *w, int *h)
{
    if (!layer || !layer.superlayer)
        return false;

    CGSize s = layer.drawableSize;
    int dw = (int)s.width;
    int dh = (int)s.height;

    // Match mpv's MetalLayer workaround: MoltenVK can transiently force
    // drawableSize to 1x1 while presenting, which causes visible flicker.
    if (dw > 1 && dh > 1) {
        *w = dw;
        *h = dh;
        return true;
    }

    CGSize bounds = layer.bounds.size;
    CGFloat scale = layer.contentsScale;
    int bw = (int)(bounds.width * scale);
    int bh = (int)(bounds.height * scale);
    if (bw > 1 && bh > 1) {
        *w = bw;
        *h = bh;
        return true;
    }

    return false;
}

static void moltenvk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
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

    if (ctx->vo->opts->WinID == -1) {
        MP_MSG(ctx, msgl, "WinID missing\n");
        goto fail;
    }

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto fail;

    p->layer = (__bridge CAMetalLayer *)(intptr_t)ctx->vo->opts->WinID;
    CFRetain((__bridge CFTypeRef)p->layer);
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
    if (get_layer_size(p->layer, &w, &h))
        ra_vk_ctx_resize(ctx, w, h);
    return true;
}

static int moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    if (request == VOCTRL_CHECK_EVENTS) {
        struct priv *p = ctx->priv;
        int w = 0;
        int h = 0;
        if (!get_layer_size(p->layer, &w, &h))
            return VO_NOTIMPL;
        if (w != ctx->vo->dwidth || h != ctx->vo->dheight) {
            ctx->vo->dwidth = w;
            ctx->vo->dheight = h;
            *events |= VO_EVENT_RESIZE;
        }
    }
    return VO_NOTIMPL;
}

const struct ra_ctx_fns ra_ctx_vulkan_moltenvk = {
    .type           = "vulkan",
    .name           = "moltenvk",
    .reconfig       = moltenvk_reconfig,
    .control        = moltenvk_control,
    .init           = moltenvk_init,
    .uninit         = moltenvk_uninit,
};
