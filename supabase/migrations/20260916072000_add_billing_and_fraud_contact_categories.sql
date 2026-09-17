-- Allow subscription-related inquiries to be routed explicitly without
-- changing existing contact-request semantics or access policies.
ALTER TABLE public.contact_requests
    DROP CONSTRAINT IF EXISTS contact_requests_category_check;

ALTER TABLE public.contact_requests
    ADD CONSTRAINT contact_requests_category_check
    CHECK (
        category IN (
            'general',
            'privacy',
            'infringement',
            'report',
            'account',
            'billing',
            'fraud',
            'other'
        )
    );
