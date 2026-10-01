if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface LrcView_Params {
    lyricMilliSecondsTime?: number;
    mLrcEntryList?: Array<LrcEntry>;
    lyricScrollEffect?: LyricScrollEffect;
    isPlay?: boolean;
    lyricTopPosition?: LyricTopPosition;
    mNormalTextColor?: string;
    viewWidth?: number;
    viewHeight?: number;
    settings?: RenderingContextSettings;
    context?: CanvasRenderingContext2D;
    mCurrentLine?: number;
    TEXT_ADD_SIZE?: number;
    lyricRectangle?: Rectangle;
    initFirstLineY?: number;
    animator?: AnimatorResult | null;
    mNormalTextSize?: number;
    mDividerHeight?: number;
    mCurrentTextSize?: number;
    fontFamily?: string;
    mCurrentTextColor?: string;
    fontWeight?: string;
    paddingLeft?: number;
    paddingRight?: number;
    paddingTop?: number;
    paddingBottom?: number;
    lrcWidth?: number;
    lrcHeight?: number;
    lrcX?: number;
    lrcY?: number;
    curCanvasOffsetY?: number;
    starAverageAngle?: number;
    starOutCircleAngle?: number;
    starInCircleAngle?: number;
    starsPath2D?: Path2D;
    starsColor?: string;
}
import type { AnimatorOptions } from "@ohos:animator";
import type { AnimatorResult } from "@ohos:animator";
import type { LrcEntry } from './LrcEntry';
import { angleToRadian } from "@normalized:N&&&entry/src/main/ets/lyric/LrcUtils&";
import { Rectangle, LyricTopPosition, LyricScrollEffect } from "@normalized:N&&&entry/src/main/ets/lyric/LyricConst&";
const NONE_LINE: number = -1;
const STAR_ANGLE_NUMBER: number = 5;
const EMPTY_LYRIC: LrcEntry = {
    lineStartTime: 0,
    lineDuration: 0,
    lineWords: '此歌曲为纯音乐，请您欣赏',
    words: []
};
/** 逐字渐变的进度间隔（在极小的区间内从高亮色跳回常规色） */
const GRADIENT_PROGRESS_SPACE = 0.0000001;
const GRADIENT_PROGRESS_MAX = 1 - GRADIENT_PROGRESS_SPACE;
/** Area.width/height 是 Length（number|string|Resource），归一化成 number（vp） */
function parseAreaLength(len: Length): number {
    if (typeof len === 'number') {
        return len;
    }
    if (typeof len === 'string') {
        return Number.parseFloat(len);
    }
    return 0;
}
export class LrcView extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.__lyricMilliSecondsTime = new SynchedPropertySimpleOneWayPU(params.lyricMilliSecondsTime, this, "lyricMilliSecondsTime");
        this.__mLrcEntryList = new SynchedPropertyObjectOneWayPU(params.mLrcEntryList, this, "mLrcEntryList");
        this.__lyricScrollEffect = new SynchedPropertySimpleOneWayPU(params.lyricScrollEffect, this, "lyricScrollEffect");
        this.__isPlay = new SynchedPropertySimpleOneWayPU(params.isPlay, this, "isPlay");
        this.lyricTopPosition = LyricTopPosition.Top;
        this.mNormalTextColor = '#99ffffff';
        this.viewWidth = 360;
        this.viewHeight = 500;
        this.settings = new RenderingContextSettings(true);
        this.context = new CanvasRenderingContext2D(this.settings);
        this.mCurrentLine = NONE_LINE;
        this.TEXT_ADD_SIZE = 2;
        this.lyricRectangle = new Rectangle(0, 0, 0, 0);
        this.initFirstLineY = 0;
        this.animator = null;
        this.mNormalTextSize = 20;
        this.mDividerHeight = 24;
        this.mCurrentTextSize = 24;
        this.fontFamily = 'HarmonyHeiTi';
        this.mCurrentTextColor = '#FFFFFF';
        this.fontWeight = 'bold';
        this.paddingLeft = 0;
        this.paddingRight = 0;
        this.paddingTop = 0;
        this.paddingBottom = 0;
        this.lrcWidth = 0;
        this.lrcHeight = 0;
        this.lrcX = 0;
        this.lrcY = 0;
        this.curCanvasOffsetY = 0;
        this.starAverageAngle = 0;
        this.starOutCircleAngle = 0;
        this.starInCircleAngle = 0;
        this.starsPath2D = new Path2D();
        this.starsColor = '#18BBFC';
        this.setInitiallyProvidedValue(params);
        this.declareWatch("lyricMilliSecondsTime", this.onTimeUpdated);
        this.declareWatch("mLrcEntryList", this.onLyricUpdated);
        this.declareWatch("lyricScrollEffect", this.onTimeUpdated);
        this.declareWatch("isPlay", this.playLyrics);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: LrcView_Params) {
        if (params.lyricMilliSecondsTime === undefined) {
            this.__lyricMilliSecondsTime.set(0);
        }
        if (params.mLrcEntryList === undefined) {
            this.__mLrcEntryList.set([]);
        }
        if (params.lyricScrollEffect === undefined) {
            this.__lyricScrollEffect.set(LyricScrollEffect.Line);
        }
        if (params.isPlay === undefined) {
            this.__isPlay.set(false);
        }
        if (params.lyricTopPosition !== undefined) {
            this.lyricTopPosition = params.lyricTopPosition;
        }
        if (params.mNormalTextColor !== undefined) {
            this.mNormalTextColor = params.mNormalTextColor;
        }
        if (params.viewWidth !== undefined) {
            this.viewWidth = params.viewWidth;
        }
        if (params.viewHeight !== undefined) {
            this.viewHeight = params.viewHeight;
        }
        if (params.settings !== undefined) {
            this.settings = params.settings;
        }
        if (params.context !== undefined) {
            this.context = params.context;
        }
        if (params.mCurrentLine !== undefined) {
            this.mCurrentLine = params.mCurrentLine;
        }
        if (params.TEXT_ADD_SIZE !== undefined) {
            this.TEXT_ADD_SIZE = params.TEXT_ADD_SIZE;
        }
        if (params.lyricRectangle !== undefined) {
            this.lyricRectangle = params.lyricRectangle;
        }
        if (params.initFirstLineY !== undefined) {
            this.initFirstLineY = params.initFirstLineY;
        }
        if (params.animator !== undefined) {
            this.animator = params.animator;
        }
        if (params.mNormalTextSize !== undefined) {
            this.mNormalTextSize = params.mNormalTextSize;
        }
        if (params.mDividerHeight !== undefined) {
            this.mDividerHeight = params.mDividerHeight;
        }
        if (params.mCurrentTextSize !== undefined) {
            this.mCurrentTextSize = params.mCurrentTextSize;
        }
        if (params.fontFamily !== undefined) {
            this.fontFamily = params.fontFamily;
        }
        if (params.mCurrentTextColor !== undefined) {
            this.mCurrentTextColor = params.mCurrentTextColor;
        }
        if (params.fontWeight !== undefined) {
            this.fontWeight = params.fontWeight;
        }
        if (params.paddingLeft !== undefined) {
            this.paddingLeft = params.paddingLeft;
        }
        if (params.paddingRight !== undefined) {
            this.paddingRight = params.paddingRight;
        }
        if (params.paddingTop !== undefined) {
            this.paddingTop = params.paddingTop;
        }
        if (params.paddingBottom !== undefined) {
            this.paddingBottom = params.paddingBottom;
        }
        if (params.lrcWidth !== undefined) {
            this.lrcWidth = params.lrcWidth;
        }
        if (params.lrcHeight !== undefined) {
            this.lrcHeight = params.lrcHeight;
        }
        if (params.lrcX !== undefined) {
            this.lrcX = params.lrcX;
        }
        if (params.lrcY !== undefined) {
            this.lrcY = params.lrcY;
        }
        if (params.curCanvasOffsetY !== undefined) {
            this.curCanvasOffsetY = params.curCanvasOffsetY;
        }
        if (params.starAverageAngle !== undefined) {
            this.starAverageAngle = params.starAverageAngle;
        }
        if (params.starOutCircleAngle !== undefined) {
            this.starOutCircleAngle = params.starOutCircleAngle;
        }
        if (params.starInCircleAngle !== undefined) {
            this.starInCircleAngle = params.starInCircleAngle;
        }
        if (params.starsPath2D !== undefined) {
            this.starsPath2D = params.starsPath2D;
        }
        if (params.starsColor !== undefined) {
            this.starsColor = params.starsColor;
        }
    }
    updateStateVars(params: LrcView_Params) {
        this.__lyricMilliSecondsTime.reset(params.lyricMilliSecondsTime);
        this.__mLrcEntryList.reset(params.mLrcEntryList);
        this.__lyricScrollEffect.reset(params.lyricScrollEffect);
        this.__isPlay.reset(params.isPlay);
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__lyricMilliSecondsTime.purgeDependencyOnElmtId(rmElmtId);
        this.__mLrcEntryList.purgeDependencyOnElmtId(rmElmtId);
        this.__lyricScrollEffect.purgeDependencyOnElmtId(rmElmtId);
        this.__isPlay.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__lyricMilliSecondsTime.aboutToBeDeleted();
        this.__mLrcEntryList.aboutToBeDeleted();
        this.__lyricScrollEffect.aboutToBeDeleted();
        this.__isPlay.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private __lyricMilliSecondsTime: SynchedPropertySimpleOneWayPU<number>;
    get lyricMilliSecondsTime() {
        return this.__lyricMilliSecondsTime.get();
    }
    set lyricMilliSecondsTime(newValue: number) {
        this.__lyricMilliSecondsTime.set(newValue);
    }
    private __mLrcEntryList: SynchedPropertySimpleOneWayPU<Array<LrcEntry>>;
    get mLrcEntryList() {
        return this.__mLrcEntryList.get();
    }
    set mLrcEntryList(newValue: Array<LrcEntry>) {
        this.__mLrcEntryList.set(newValue);
    }
    private __lyricScrollEffect: SynchedPropertySimpleOneWayPU<LyricScrollEffect>;
    get lyricScrollEffect() {
        return this.__lyricScrollEffect.get();
    }
    set lyricScrollEffect(newValue: LyricScrollEffect) {
        this.__lyricScrollEffect.set(newValue);
    }
    /** 播放状态：暂停时挂起滚动补间 */
    private __isPlay: SynchedPropertySimpleOneWayPU<boolean>;
    get isPlay() {
        return this.__isPlay.get();
    }
    set isPlay(newValue: boolean) {
        this.__isPlay.set(newValue);
    }
    private lyricTopPosition: LyricTopPosition;
    private readonly mNormalTextColor: string;
    private viewWidth: number;
    private viewHeight: number;
    private settings: RenderingContextSettings;
    private context: CanvasRenderingContext2D;
    private mCurrentLine: number;
    private readonly TEXT_ADD_SIZE: number;
    private lyricRectangle: Rectangle;
    /** 首行歌词的初始 Y（Middle 时取内容区上部约 1/2.8 处） */
    private initFirstLineY: number;
    /** 滚动补间（aboutToAppear 里经 UIContext 创建） */
    private animator: AnimatorResult | null;
    private mNormalTextSize: number;
    private mDividerHeight: number;
    private mCurrentTextSize: number;
    private fontFamily: string;
    private mCurrentTextColor: string;
    private fontWeight: string;
    private paddingLeft: number;
    private paddingRight: number;
    private paddingTop: number;
    private paddingBottom: number;
    private lrcWidth: number;
    private lrcHeight: number;
    private lrcX: number;
    private lrcY: number;
    private curCanvasOffsetY: number;
    private starAverageAngle: number;
    private starOutCircleAngle: number;
    private starInCircleAngle: number;
    private starsPath2D: Path2D;
    private starsColor: string;
    aboutToAppear(): void {
        const options: AnimatorOptions = {
            duration: 400,
            easing: 'linear',
            delay: 0,
            fill: 'forwards',
            direction: 'normal',
            iterations: 1,
            begin: 0,
            end: 1
        };
        this.animator = this.getUIContext().createAnimator(options);
    }
    aboutToDisappear(): void {
        if (this.animator !== null) {
            this.animator.finish();
            this.animator = null;
        }
    }
    /** 滚动到目标偏移：从当前偏移补间到 -desOffsetY（ease-in-out 起收都缓，换行不突兀） */
    startAnimator(desOffsetY: number): void {
        if (this.animator === null) {
            return;
        }
        this.animator.finish();
        const options: AnimatorOptions = {
            duration: 400,
            easing: 'ease-in-out',
            delay: 0,
            fill: 'forwards',
            direction: 'normal',
            iterations: 1,
            begin: this.curCanvasOffsetY,
            end: -desOffsetY
        };
        this.animator = this.getUIContext().createAnimator(options);
        console.info(`[LrcView] startAnimator curOffset: ${this.curCanvasOffsetY}, desOffset: ${-desOffsetY}`);
        this.animator.onFrame = (value: number): void => {
            this.drawContent(value);
        };
        this.animator.onCancel = (): void => {
        };
        this.animator.onFinish = (): void => {
        };
        this.animator.play();
    }
    playLyrics(): void {
        if (this.animator === null) {
            return;
        }
        if (this.isPlay) {
            this.animator.play();
        }
        else {
            this.animator.pause();
        }
    }
    /** 画一颗五角星（LetterStar 特效用，行级歌词不会走到） */
    private drawStars(x: number, y: number, outRadius: number, inRadius: number, rotateAngle: number): void {
        this.starsPath2D = new Path2D();
        this.context.fillStyle = this.starsColor;
        for (let i = 0; i < STAR_ANGLE_NUMBER; i++) {
            let outX = (Math.cos(angleToRadian(rotateAngle + this.starOutCircleAngle + i * this.starAverageAngle)) * outRadius) + x;
            let outY = -(Math.sin(angleToRadian(rotateAngle + this.starOutCircleAngle + i * this.starAverageAngle)) * outRadius) + y;
            let inX = (Math.cos(angleToRadian(rotateAngle + this.starInCircleAngle + i * this.starAverageAngle)) * inRadius) + x;
            let inY = -(Math.sin(angleToRadian(rotateAngle + this.starInCircleAngle + i * this.starAverageAngle)) * inRadius) + y;
            if (i === 0) {
                this.starsPath2D.moveTo(outX, outY);
            }
            this.starsPath2D.lineTo(outX, outY);
            this.starsPath2D.lineTo(inX, inY);
        }
        this.starsPath2D.closePath();
        this.context.fill(this.starsPath2D);
    }
    private calculate(): void {
        this.lrcWidth = this.viewWidth - this.paddingLeft - this.paddingRight;
        this.lrcHeight = this.viewHeight - this.paddingTop - this.paddingBottom;
        if (this.initFirstLineY === 0) {
            switch (this.lyricTopPosition) {
                case LyricTopPosition.Middle:
                    this.initFirstLineY = this.paddingTop + this.lrcHeight / 2.8;
                    break;
                case LyricTopPosition.Top:
                    this.initFirstLineY = this.paddingTop;
                    break;
                default:
                    break;
            }
        }
        this.lrcX = 0;
        this.lrcY = this.initFirstLineY;
        this.starAverageAngle = 360 / STAR_ANGLE_NUMBER;
        this.starOutCircleAngle = 90 - this.starAverageAngle;
        let halfAverageAngle = this.starAverageAngle / 2;
        this.starInCircleAngle = halfAverageAngle + this.starOutCircleAngle;
    }
    private reset(): void {
        this.lrcY = this.initFirstLineY;
    }
    /** 单行文本高度（含折行） */
    private getLineHeight(text: string, isCurrent?: boolean): number {
        let lineHeight = 0;
        if (isCurrent) {
            this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
        }
        else {
            this.context.font = this.fontWeight + ' ' + this.mNormalTextSize + 'vp ' + this.fontFamily;
        }
        let textMetrics: TextMetrics = this.context.measureText(text);
        if (textMetrics.width > this.lrcWidth) {
            let start = 0;
            let end = text.length - 1;
            let textTemp = text;
            while (this.context.measureText(text.substring(start, end)).width > this.lrcWidth) {
                if (textTemp.lastIndexOf(' ') !== -1) {
                    end = textTemp.lastIndexOf(' ');
                    textTemp = textTemp.substring(0, end);
                }
                else {
                    end--;
                }
            }
            if (this.context.measureText(text.substring(start, end)).width <= this.lrcWidth) {
                lineHeight += textMetrics.height;
                start = end;
            }
            if (start < text.length - 1) {
                lineHeight += textMetrics.height;
            }
        }
        else {
            lineHeight = textMetrics.height;
        }
        return lineHeight;
    }
    private progressGrad(startX: number, startY: number, endX: number, endY: number, progress: number): CanvasGradient {
        let grad = this.context.createLinearGradient(startX, startY, endX, endY);
        grad.addColorStop(progress, this.mCurrentTextColor);
        grad.addColorStop(progress + GRADIENT_PROGRESS_SPACE, this.mNormalTextColor);
        return grad;
    }
    /** 折行绘制（文本超宽时按空格断行） */
    private drawMultipleLine(lyric: LrcEntry, textMetrics: TextMetrics): number {
        let lineHeight = 0;
        let start = 0;
        let end = 1;
        this.context.textAlign = 'start';
        let text = lyric.lineWords;
        let textTemp = lyric.lineWords;
        end = text.length - 1;
        while (this.context.measureText(text.substring(start, end)).width > this.lrcWidth) {
            if (textTemp.lastIndexOf(' ') !== -1) {
                end = textTemp.lastIndexOf(' ');
                textTemp = textTemp.substring(0, end);
            }
            else {
                end--;
            }
        }
        if (this.context.measureText(text.substring(start, end)).width <= this.lrcWidth) {
            if (start === 0) {
                this.lrcY = this.lrcY + textMetrics.height + this.mDividerHeight;
            }
            else {
                this.lrcY = this.lrcY + textMetrics.height;
            }
            lineHeight += textMetrics.height;
            this.context.fillText(text.substring(start, end), this.lrcX, this.lrcY, this.lrcWidth);
            start = end;
        }
        if (start !== 0 && text.charAt(start) === ' ') {
            start += 1;
        }
        if (start < text.length - 1) {
            this.lrcY = this.lrcY + textMetrics.height;
            lineHeight += textMetrics.height;
            this.context.fillText(text.substring(start), this.lrcX, this.lrcY, this.lrcWidth);
        }
        return lineHeight;
    }
    /** 单行绘制（当前行按滚动效果分支；行级歌词 words 为空，走 default 左对齐） */
    private drawSingleLine(lyric: LrcEntry, textMetrics: TextMetrics, isCurrent: boolean): number {
        this.lrcY = this.lrcY + this.mDividerHeight + textMetrics.height;
        let text = lyric.lineWords;
        if (isCurrent) {
            switch (this.lyricScrollEffect) {
                case LyricScrollEffect.LetterScaleGradient:
                    if (lyric.words && lyric.words.length > 0) {
                        let startX = this.lrcX - textMetrics.width / 2;
                        let endX = startX + textMetrics.width;
                        let gradY = this.lrcY - textMetrics.height / 2;
                        let wordX = startX;
                        this.context.textAlign = 'start';
                        for (let i = 0; i < lyric.words.length; i++) {
                            let wordStartTime = lyric.lineStartTime + lyric.words[i].wordStartTime;
                            let wordEndTime = lyric.lineStartTime + lyric.words[i].wordStartTime + lyric.words[i].duration;
                            if (wordStartTime <= this.lyricMilliSecondsTime && wordEndTime >= this.lyricMilliSecondsTime) {
                                let wordProgress = (this.lyricMilliSecondsTime - wordStartTime) / lyric.words[i].duration / lyric.words.length;
                                let wordPassedProgress = i / lyric.words.length;
                                let progress = wordPassedProgress + wordProgress;
                                this.context.fillStyle = this.progressGrad(startX, gradY, endX, gradY, progress);
                                this.context.font =
                                    this.fontWeight + ' ' + (this.mCurrentTextSize + this.TEXT_ADD_SIZE) + 'vp ' + this.fontFamily;
                                this.context.fillText(lyric.words[i].text, wordX, this.lrcY + this.TEXT_ADD_SIZE / 2, this.lrcWidth);
                            }
                            else {
                                this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
                                this.context.fillText(lyric.words[i].text, wordX, this.lrcY, this.lrcWidth);
                            }
                            wordX += this.context.measureText(lyric.words[i].text).width;
                        }
                    }
                    else {
                        this.context.textAlign = 'center';
                        this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
                    }
                    break;
                case LyricScrollEffect.LetterGradient:
                    if (lyric.words && lyric.words.length > 0) {
                        this.context.textAlign = 'center';
                        let startX_g = this.lrcX - textMetrics.width / 2;
                        let endX_g = startX_g + textMetrics.width;
                        let gradY_g = this.lrcY - textMetrics.height / 2;
                        let progress = 0;
                        let findPlayingWord = false;
                        for (let i = 0; i < lyric.words.length; i++) {
                            let wordStartTime = lyric.lineStartTime + lyric.words[i].wordStartTime;
                            let wordEndTime = lyric.lineStartTime + lyric.words[i].wordStartTime + lyric.words[i].duration;
                            if (wordStartTime <= this.lyricMilliSecondsTime && wordEndTime >= this.lyricMilliSecondsTime) {
                                let wordProgress = (this.lyricMilliSecondsTime - wordStartTime) / lyric.words[i].duration / lyric.words.length;
                                let wordPassedProgress = i / lyric.words.length;
                                progress = wordPassedProgress + wordProgress;
                                findPlayingWord = true;
                                break;
                            }
                        }
                        if (!findPlayingWord) {
                            if (this.lyricMilliSecondsTime < lyric.lineStartTime) {
                                progress = 0;
                            }
                            else if (this.lyricMilliSecondsTime >= lyric.lineStartTime + lyric.lineDuration) {
                                progress = GRADIENT_PROGRESS_MAX;
                            }
                            else {
                                console.error('This should not be happening.');
                            }
                        }
                        this.context.fillStyle = this.progressGrad(startX_g, gradY_g, endX_g, gradY_g, progress);
                        this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
                    }
                    else {
                        this.context.textAlign = 'center';
                        this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
                    }
                    break;
                case LyricScrollEffect.LetterStar:
                    if (lyric.words && lyric.words.length > 0) {
                        let textStartX = this.lrcX - textMetrics.width / 2;
                        let textEndX = textStartX + textMetrics.width;
                        let gradY_Star = this.lrcY - textMetrics.height / 2;
                        let wordXX = textStartX;
                        let starX = textStartX;
                        let starRotate = 0;
                        this.context.textAlign = 'start';
                        let findPlayingWordStar = false;
                        for (let i = 0; i < lyric.words.length; i++) {
                            let wordStartTime = lyric.lineStartTime + lyric.words[i].wordStartTime;
                            let wordEndTime = lyric.lineStartTime + lyric.words[i].wordStartTime + lyric.words[i].duration;
                            if (wordStartTime <= this.lyricMilliSecondsTime && wordEndTime >= this.lyricMilliSecondsTime) {
                                let wordProgress = (this.lyricMilliSecondsTime - wordStartTime) / lyric.words[i].duration / lyric.words.length;
                                let wordPassedProgress = i / lyric.words.length;
                                let progress = wordPassedProgress + wordProgress;
                                this.context.fillStyle = this.progressGrad(textStartX, gradY_Star, textEndX, gradY_Star, progress);
                                this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
                                this.context.fillText(lyric.words[i].text, wordXX, this.lrcY, this.lrcWidth);
                                findPlayingWordStar = true;
                                starX = wordXX + this.context.measureText(lyric.words[i].text).width / 2;
                            }
                            else {
                                this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
                                this.context.fillText(lyric.words[i].text, wordXX, this.lrcY, this.lrcWidth);
                            }
                            wordXX += this.context.measureText(lyric.words[i].text).width;
                        }
                        if (!findPlayingWordStar) {
                            if (this.lyricMilliSecondsTime < lyric.lineStartTime) {
                                starX = textStartX;
                            }
                            else if (this.lyricMilliSecondsTime > lyric.lineStartTime + lyric.lineDuration) {
                                starX = this.lrcX + textMetrics.width / 2 -
                                    this.context.measureText(lyric.words[lyric.words.length - 1].text).width / 2;
                            }
                            else {
                                console.error('This should not be happening.');
                            }
                        }
                        let starY = this.lrcY - textMetrics.height;
                        this.drawStars(starX, starY, this.mDividerHeight / 2, this.mDividerHeight / 4, starRotate);
                    }
                    else {
                        this.context.textAlign = 'center';
                        this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
                    }
                    break;
                default:
                    this.context.textAlign = 'start';
                    this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
                    break;
            }
        }
        else {
            this.context.textAlign = 'start';
            this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
        }
        return textMetrics.height;
    }
    private drawLyricLine(lyric: LrcEntry, isCurrent: boolean): number {
        let lineHeight = 0;
        if (isCurrent) {
            this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
            this.context.fillStyle = this.mCurrentTextColor;
            // 当前行柔和文字发光：低强度白影，只烘托高亮、不做闪烁
            this.context.shadowBlur = 12;
            this.context.shadowColor = 'rgba(255, 255, 255, 0.35)';
        }
        else {
            this.context.font = this.fontWeight + ' ' + this.mNormalTextSize + 'vp ' + this.fontFamily;
            this.context.fillStyle = this.mNormalTextColor;
        }
        this.context.textBaseline = 'bottom';
        let textMetrics: TextMetrics = this.context.measureText(lyric.lineWords);
        if (textMetrics.width > this.lrcWidth) {
            lineHeight = this.drawMultipleLine(lyric, textMetrics);
        }
        else {
            lineHeight = this.drawSingleLine(lyric, textMetrics, isCurrent);
        }
        // 发影用完即关：渐隐遮罩 fillRect 不能带 shadow，否则整屏泛光
        this.context.shadowBlur = 0;
        return lineHeight;
    }
    private drawContent(desOffsetY: number): void {
        this.context.clearRect(0, 0, this.viewWidth, this.lrcY + this.viewHeight);
        this.reset();
        this.context.globalCompositeOperation = 'source-over';
        this.lrcY = this.initFirstLineY + desOffsetY;
        this.curCanvasOffsetY = desOffsetY;
        if (this.mLrcEntryList && this.mLrcEntryList.length > 0) {
            let index = 0;
            for (let mLrcEntryListElement of this.mLrcEntryList) {
                let isCurrentLine = this.mCurrentLine === index ? true : false;
                this.drawLyricLine(mLrcEntryListElement, isCurrentLine);
                index++;
            }
        }
        else {
            this.drawLyricLine(EMPTY_LYRIC, true);
        }
        this.updateLyricArea(this.paddingLeft, this.paddingTop, this.viewWidth - this.paddingRight, this.viewHeight - this.paddingBottom);
        if (this.mLrcEntryList && this.mLrcEntryList.length > 0) {
            // 上下渐隐遮罩：先按歌词形状填充，再用透明渐变以 source-in 方式裁剪
            this.context.globalCompositeOperation = 'source-in';
            let grad = this.context.createLinearGradient(0, 0, 0, this.viewHeight);
            grad.addColorStop(0.0, '#00ffffff');
            grad.addColorStop(0.15, '#ffffffff');
            grad.addColorStop(0.3, '#ffffffff');
            grad.addColorStop(0.7, '#4dffffff');
            grad.addColorStop(1.0, '#00ffffff');
            this.context.fillStyle = grad;
            this.context.fillRect(0, 0, this.viewWidth, this.viewHeight);
        }
    }
    private updateLyricArea(left: number, top: number, right: number, bottom: number): void {
        this.lyricRectangle = new Rectangle(left, top, right, bottom);
    }
    hasLrc(): boolean {
        return this.mLrcEntryList && this.mLrcEntryList.length > 0;
    }
    getOffset(line: number): number {
        let offsetY = 0;
        switch (this.lyricTopPosition) {
            case LyricTopPosition.Top:
                for (let i = 0; i <= line && i < this.mLrcEntryList.length; i++) {
                    if (i === line) {
                        offsetY += this.getLineHeight(this.mLrcEntryList[i].lineWords, true) / 2
                            - this.getLineHeight(this.mLrcEntryList[i].lineWords, false) / 2;
                    }
                    else {
                        offsetY += this.getLineHeight(this.mLrcEntryList[i].lineWords, false) + this.mDividerHeight;
                    }
                }
                break;
            case LyricTopPosition.Middle:
                for (let i = 0; i <= line && i < this.mLrcEntryList.length; i++) {
                    if (i === line) {
                        offsetY += this.getLineHeight(this.mLrcEntryList[i].lineWords, true) / 2 + this.mDividerHeight;
                    }
                    else {
                        offsetY += this.getLineHeight(this.mLrcEntryList[i].lineWords, false) + this.mDividerHeight;
                    }
                }
                break;
            default:
                break;
        }
        return offsetY;
    }
    smoothScrollTo(line: number): void {
        let offset = this.getOffset(line);
        console.info(`[LrcView] smoothScrollTo line: ${line}, offset: ${offset}`);
        this.startAnimator(offset);
    }
    /** 歌词内容变化：清空高亮并按当前时间重绘 */
    onLyricUpdated(): void {
        this.mCurrentLine = NONE_LINE;
        this.onTimeUpdated();
    }
    /** 时间更新：换行时平滑滚动，同行内直接重绘 */
    onTimeUpdated(): void {
        if (!this.hasLrc()) {
            this.drawContent(0);
            return;
        }
        let line = this.findShowLine(this.lyricMilliSecondsTime);
        if (line !== this.mCurrentLine) {
            this.mCurrentLine = line;
            this.smoothScrollTo(line);
        }
        else {
            this.drawContent(this.curCanvasOffsetY);
        }
    }
    findShowLine(milliSeconds: number): number {
        if (this.mLrcEntryList && this.mLrcEntryList.length > 0) {
            for (let index = 0; index < this.mLrcEntryList.length; index++) {
                if (this.mLrcEntryList[index].lineStartTime <= milliSeconds
                    && this.mLrcEntryList[index].lineStartTime + this.mLrcEntryList[index].lineDuration >= milliSeconds) {
                    return index;
                }
            }
        }
        return this.mCurrentLine;
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Canvas.create(this.context);
            Canvas.onAreaChange((oldArea: Area, newArea: Area) => {
                this.viewWidth = parseAreaLength(newArea.width);
                this.viewHeight = parseAreaLength(newArea.height);
                if (parseAreaLength(oldArea.width) !== parseAreaLength(newArea.width)
                    || parseAreaLength(oldArea.height) !== parseAreaLength(newArea.height)) {
                    this.calculate();
                    let line = this.findShowLine(this.lyricMilliSecondsTime);
                    let offset = this.getOffset(line);
                    this.drawContent(-offset);
                }
            });
        }, Canvas);
        Canvas.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
}
