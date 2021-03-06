//
//  mruby View Controller Implementation
//

#import "MrubyViewController.h"

#import "FCFileManager.h"
#import "mrb_image.h"
#import "mrb_misc.h"
#import "mruby.h"
#import "mruby/array.h"
#import "mruby/class.h"
#import "mruby/compile.h"
#import "mruby/error.h"
#import "mruby/irep.h"
#import "mruby/string.h"
#import "mruby/variable.h"

MrubyViewController *globalMrubyViewController;

@implementation MrubyViewController {
    NSString* _scriptPath;
    mrb_state* _mrb;
    UITextView* _textView;
    BOOL _isCanceled;
    NSMutableArray* _receivePicked;
    QBImagePickerController* _imagePicker;
}

- (id)initWithScriptPath:(NSString*)scriptPath {
    self = [super init];

    globalMrubyViewController = self;

    _scriptPath = scriptPath;
    _mrb = [self initMrb];
    _isCanceled = NO;

    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // TextView
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.editable = NO;
    _textView.dataDetectorTypes = UIDataDetectorTypeLink;
    _textView.font = [UIFont fontWithName:@"Courier" size:12];
    _textView.text = @"";
    [self.view addSubview:_textView];

    // ImagePicker
    _imagePicker = [QBImagePickerController new];
    [_imagePicker setDelegate:self];
    _imagePicker.showsNumberOfSelectedAssets = YES;

    // Run script
    [self runMrb];
}

- (void)didMoveToParentViewController:(UIViewController *)parent {
    if (![parent isEqual:self.parentViewController]) {
        if (_mrb) {
            // NSLog(@"Start cancel");
            _isCanceled = YES;
        }
    }
}

static void
mrb_hook(struct mrb_state* mrb, struct mrb_irep *irep, mrb_code *pc, mrb_value *regs)
{
    if ([globalMrubyViewController isCanceled]) {
        mrb_raise(mrb, E_RUNTIME_ERROR, "Cancel from MrubyViewController");
    }
}

- (mrb_state*)initMrb {
    mrb_state* mrb = mrb_open();

    // Set hook
    mrb->code_fetch_hook = mrb_hook;

    // Bind
    mrb_rubypico_image_init(mrb);
    mrb_rubypico_misc_init(mrb);

    // Load builtin library
    {
        NSString* path = [FCFileManager pathForMainBundleDirectoryWithPath:@"__builtin__.rb"];
        char* scriptPath = (char *)[path UTF8String];
        FILE *fd = fopen(scriptPath, "r");
        mrb_load_file(mrb, fd);
        fclose(fd);
    }
 
    // Set LOAD_PATH($:)
    {
        mrb_value load_path = mrb_gv_get(mrb, mrb_intern_cstr(mrb, "$:"));
        mrb_ary_push(mrb, load_path, mrb_str_new_cstr(mrb, [[FCFileManager pathForDocumentsDirectory] UTF8String]));
        mrb_ary_push(mrb, load_path, mrb_str_new_cstr(mrb, [[FCFileManager pathForMainBundleDirectory] UTF8String]));
        // mrb_p(mrb, load_path);
    }

    return mrb;
}

- (void)runMrb {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int arena = mrb_gc_arena_save(_mrb);

        {
            char* scriptPath = (char *)[_scriptPath UTF8String];
            FILE *fd = fopen(scriptPath, "r");

            mrbc_context *cxt = mrbc_context_new(_mrb);

            const char* fileName = [[[[NSString alloc] initWithUTF8String:scriptPath] lastPathComponent] UTF8String];
            mrbc_filename(_mrb, cxt, fileName);
            mrb_gv_set(_mrb, mrb_intern(_mrb, "$0", 2), mrb_str_new_cstr(_mrb, fileName));

            // Run Top Level
            mrb_load_file_cxt(_mrb, fd, cxt);

            // Error handling
            if (_mrb->exc) {
                rubypico_misc_p(_mrb, mrb_obj_value(_mrb->exc));
            }

            mrbc_context_free(_mrb, cxt);

            fclose(fd);
        }

        mrb_gc_arena_restore(_mrb, arena);

        _mrb = NULL;
        // NSLog(@"Finish mruby");
    });
}

- (void)appendAttributedString:(NSAttributedString*)attrStr {
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] init];
    [attributedString appendAttributedString: _textView.attributedText];
    [attributedString appendAttributedString: attrStr];
    _textView.attributedText = attributedString;
}

- (void)printstr:(NSString*)str {
    [self appendAttributedString:[[NSAttributedString alloc] initWithString:str]];
}

- (void)printimage:(UIImage*)image {
    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = image;
    const float MARGIN = 10.0f;
    const float WIDTH = [_textView bounds].size.width - MARGIN;
    if (image.size.width > WIDTH) {
        attachment.bounds = CGRectMake(0.0f, 0.0f, WIDTH, image.size.height / image.size.width * WIDTH);
    }

    [self appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
}

- (BOOL)isCanceled {
    return _isCanceled;
}

- (void) startPopupInput:(NSString*)path {
    _receivePicked = NULL;

    UIAlertView* alert = [[UIAlertView alloc] init];
    alert.title = path;
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertViewStyle:UIAlertViewStylePlainTextInput];
    alert.delegate = self;
    alert.cancelButtonIndex = 0;
    [alert show];
}

- (void) startPopupMsg:(NSString*)path {
    _receivePicked = NULL;

    UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@""
                                                    message:path
                                                   delegate:self
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
}

- (void)alertView:(UIAlertView*)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    @synchronized (self) {
        _receivePicked = [[NSMutableArray alloc] initWithCapacity:1];

        if (buttonIndex == alertView.cancelButtonIndex) {
            return;
        }

        NSString* text = [[alertView textFieldAtIndex:0] text];
        [_receivePicked addObject:text];
    }
}

- (NSMutableArray*) receivePicked {
    @synchronized (self) {
        NSMutableArray* array = _receivePicked;
        _receivePicked = NULL;
        return array;
    }
}

- (void) startPickFromLibrary:(int)num {
    _receivePicked = NULL;
    _imagePicker.allowsMultipleSelection = (num > 1) ? YES : NO;
    _imagePicker.maximumNumberOfSelection = num;
    [self presentViewController:_imagePicker animated:YES completion:nil];
}

- (void)qb_imagePickerController:(QBImagePickerController *)picker didFinishPickingAssets:(NSArray *)assets {
    @synchronized (self) {
        _receivePicked = [[NSMutableArray alloc] initWithCapacity:[assets count]];

        PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
        options.synchronous = YES;
        options.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
        options.resizeMode = PHImageRequestOptionsResizeModeExact;

        for (PHAsset* asset in assets) {
            [[PHImageManager defaultManager] requestImageForAsset:asset
                                                    targetSize:PHImageManagerMaximumSize
                                                    contentMode:PHImageContentModeAspectFit
                                                        options:options
                                                    resultHandler:^(UIImage *result, NSDictionary *info) {
                    if (result) {
                        [_receivePicked addObject:result];
                    }
                }];
        }

        [self dismissViewControllerAnimated:YES completion:NULL];
    }
}

- (void)qb_imagePickerControllerDidCancel:(QBImagePickerController *)picker {
    @synchronized (self) {
        [self dismissViewControllerAnimated:YES completion:NULL];
    }
}

@end
